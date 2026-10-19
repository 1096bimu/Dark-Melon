import Foundation
import CoreGraphics
import CoreImage

nonisolated struct RAWWhitePoint: Sendable {
    let chromaticity: CGPoint
    let temperature: Double
    let tint: Double

    init?(chromaticity: CGPoint, temperature: Double, tint: Double) {
        guard chromaticity.x.isFinite, chromaticity.y.isFinite,
              chromaticity.x > 0, chromaticity.y > 0,
              chromaticity.x + chromaticity.y < 1,
              temperature.isFinite, temperature > 0, tint.isFinite else { return nil }
        self.chromaticity = chromaticity
        self.temperature = temperature
        self.tint = tint
    }
}

/// Blackbody reference at a fixed exposure convention, not a scene CCT meter.
nonisolated enum TemperatureLocus {
    struct Sample: Sendable {
        let kelvin: Int
        let point: CGPoint // Same screen-oriented Lab a*/b* coordinates as the GPU scope.
    }
    static let marks = [2000, 3200, 4000, 5000, 6500, 8000]
    static let temperatures = Array(stride(from: 2000, through: 8000, by: 25))
    private static let references = Dictionary(uniqueKeysWithValues: ProcessingColorSpace.allCases.map { space in
        (space, temperatures.map { referenceRGB($0, space: space) })
    })

    static func referenceImage(for space: ProcessingColorSpace, black: Double, white: Double, whitePoint: RAWWhitePoint? = nil) -> CIImage {
        let scale = (black + 0.5 * (white - black)) / 0.5
        let colors = whitePoint.map { reference in temperatures.map { referenceRGB($0, space: space, whitePoint: reference) } } ?? references[space]!
        let pixels = colors.flatMap { [Float($0.x * scale), Float($0.y * scale), Float($0.z * scale), Float(1)] }
        let data = pixels.withUnsafeBytes { Data($0) }
        return CIImage(bitmapData: data, bytesPerRow: pixels.count * 4,
                       size: CGSize(width: temperatures.count, height: 1),
                       format: .RGBAf, colorSpace: space.linear)
    }

    static func samples(encodedPixels: [UInt8], space: ProcessingColorSpace = .sRGB) -> [Sample] {
        temperatures.enumerated().map { index, kelvin in
            let offset = index * 4
            return plotted(kelvin: kelvin, r: Double(encodedPixels[offset]) / 255,
                           g: Double(encodedPixels[offset + 1]) / 255,
                           b: Double(encodedPixels[offset + 2]) / 255, space: space)
        }
    }

    static func chromaticity(_ kelvin: Double) -> CGPoint {
        // Kang et al. (2002) approximation, valid over 1667–25000 K.
        // https://colour.readthedocs.io/en/develop/generated/colour.temperature.CCT_to_xy_Kang2002.html
        let t = kelvin, t2 = t * t, t3 = t2 * t
        let x = t <= 4000
            ? -0.2661239e9 / t3 - 0.2343589e6 / t2 + 0.8776956e3 / t + 0.179910
            : -3.0258469e9 / t3 + 2.1070379e6 / t2 + 0.2226347e3 / t + 0.240390
        let y: Double
        if t <= 2222 {
            y = -1.1063814 * x * x * x - 1.34811020 * x * x + 2.18555832 * x - 0.20219683
        } else if t <= 4000 {
            y = -0.9549476 * x * x * x - 1.37418593 * x * x + 2.09137015 * x - 0.16748867
        } else {
            y = 3.0817580 * x * x * x - 5.8733867 * x * x + 3.75112997 * x - 0.37001483
        }
        return CGPoint(x: x, y: y)
    }

    static func referenceRGB(_ kelvin: Int, space: ProcessingColorSpace, whitePoint: RAWWhitePoint? = nil) -> SIMD3<Double> {
        let xy = chromaticity(Double(kelvin))
        var xyz = SIMD3(xy.x / xy.y, 1, (1 - xy.x - xy.y) / xy.y)
        if let whitePoint { xyz = adaptedXYZ(xyz, from: whitePoint.chromaticity) }
        xyz *= 1 / xyz.y
        // XYZ -> selected D65 RGB. RAW references first account for the decoder white point.
        let rows: [SIMD3<Double>]
        switch space {
        case .sRGB:
            rows = [SIMD3(3.24096994, -1.53738318, -0.49861076), SIMD3(-0.96924364, 1.87596750, 0.04155506), SIMD3(0.05563008, -0.20397696, 1.05697151)]
        case .displayP3:
            rows = [SIMD3(2.49349691, -0.93138362, -0.40271078), SIMD3(-0.82948897, 1.76266406, 0.02362469), SIMD3(0.03584583, -0.07617239, 0.95688452)]
        case .rec2020:
            rows = [SIMD3(1.71665119, -0.35567078, -0.25336628), SIMD3(-0.66668435, 1.61648124, 0.01576855), SIMD3(0.01763986, -0.04277061, 0.94210312)]
        }
        // XYZ was constructed with Y = 1; scale to linear luminance Y = 0.5.
        // Preserve extended RGB values until the normal image pipeline handles them.
        let rgb = rows.map { row in (row.x * xyz.x + row.y * xyz.y + row.z * xyz.z) * 0.5 }
        return SIMD3(rgb[0], rgb[1], rgb[2])
    }

    /// Bradford approximation of the adaptation already applied by the RAW decoder.
    /// The metadata xy includes tint; a blackbody at the same CCT need not be neutral.
    static func adaptedXYZ(_ xyz: SIMD3<Double>, from white: CGPoint) -> SIMD3<Double> {
        func cone(_ v: SIMD3<Double>) -> SIMD3<Double> {
            SIMD3(0.8951*v.x + 0.2664*v.y - 0.1614*v.z,
                  -0.7502*v.x + 1.7135*v.y + 0.0367*v.z,
                  0.0389*v.x - 0.0685*v.y + 1.0296*v.z)
        }
        let source = SIMD3(white.x / white.y, 1, (1 - white.x - white.y) / white.y)
        let destination = SIMD3(0.3127 / 0.3290, 1, (1 - 0.3127 - 0.3290) / 0.3290)
        let adapted = cone(xyz) * cone(destination) / cone(source)
        return SIMD3(0.9869929*adapted.x - 0.1470543*adapted.y + 0.1599627*adapted.z,
                     0.4323053*adapted.x + 0.5183603*adapted.y + 0.0492912*adapted.z,
                     -0.0085287*adapted.x + 0.0400428*adapted.y + 0.9684867*adapted.z)
    }

    private static func plotted(kelvin: Int, r: Double, g: Double, b: Double, space: ProcessingColorSpace) -> Sample {
        return Sample(kelvin: kelvin, point: ScopeProjection.point(r: r, g: g, b: b, space: space))
    }
}
