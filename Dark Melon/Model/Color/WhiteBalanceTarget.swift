import CoreGraphics
import simd

/// Scene white neutralized by the edit, independent of the decoder's as-shot white.
/// Bradford models the decoder adaptation approximately; this is not a camera profile.
nonisolated struct WhiteBalanceTarget: Codable, Sendable {
    let x: Double
    let y: Double

    private var isValid: Bool {
        x.isFinite && y.isFinite && x > 0 && y > 0 && x + y < 1
    }
    private static let d65 = CGPoint(x: 0.3127, y: 0.3290)
    private static let bradford = simd_double3x3(rows: [
        SIMD3(0.8951, 0.2664, -0.1614),
        SIMD3(-0.7502, 1.7135, 0.0367),
        SIMD3(0.0389, -0.0685, 1.0296)])

    private static func xyz(_ xy: CGPoint) -> SIMD3<Double> {
        SIMD3(xy.x / xy.y, 1, (1 - xy.x - xy.y) / xy.y)
    }
    private static func adapt(_ value: SIMD3<Double>, from: CGPoint, to: CGPoint) -> SIMD3<Double> {
        bradford.inverse * ((bradford * value) * (bradford * xyz(to)) / (bradford * xyz(from)))
    }
    private static func rgbMatrix(_ space: ProcessingColorSpace) -> simd_double3x3 {
        switch space {
        case .sRGB:
            simd_double3x3(rows: [SIMD3(3.24096994, -1.53738318, -0.49861076), SIMD3(-0.96924364, 1.87596750, 0.04155506), SIMD3(0.05563008, -0.20397696, 1.05697151)])
        case .displayP3:
            simd_double3x3(rows: [SIMD3(2.49349691, -0.93138362, -0.40271078), SIMD3(-0.82948897, 1.76266406, 0.02362469), SIMD3(0.03584583, -0.07617239, 0.95688452)])
        case .rec2020:
            simd_double3x3(rows: [SIMD3(1.71665119, -0.35567078, -0.25336628), SIMD3(-0.66668435, 1.61648124, 0.01576855), SIMD3(0.01763986, -0.04277061, 0.94210312)])
        }
    }

    init?(chromaticity: CGPoint) {
        x = chromaticity.x
        y = chromaticity.y
        guard isValid else { return nil }
    }

    init?(gains: WhiteBalance, reference: CGPoint, space: ProcessingColorSpace) {
        let rgb = SIMD3(gains.red, gains.green, gains.blue)
        guard (0..<3).allSatisfy({ rgb[$0].isFinite && rgb[$0] > 0 }) else { return nil }
        // The input neutralized by diagonal gains is proportional to their reciprocal.
        let decoded = Self.rgbMatrix(space).inverse * (SIMD3<Double>(repeating: 1) / rgb)
        let scene = Self.adapt(decoded, from: Self.d65, to: reference)
        let sum = scene.x + scene.y + scene.z
        x = scene.x / sum
        y = scene.y / sum
        guard isValid else { return nil }
    }

    func gains(reference: CGPoint, space: ProcessingColorSpace) -> WhiteBalance? {
        guard isValid else { return nil }
        let decoded = Self.adapt(Self.xyz(CGPoint(x: x, y: y)), from: reference, to: Self.d65)
        let rgb = Self.rgbMatrix(space) * decoded
        guard (0..<3).allSatisfy({ rgb[$0].isFinite && rgb[$0] > 0 }) else { return nil }
        var gains = SIMD3<Double>(repeating: 1) / rgb
        gains /= simd_dot(gains, space.luminance)
        guard (0..<3).allSatisfy({ gains[$0].isFinite && (0.000001...10000).contains(gains[$0]) }) else { return nil }
        return WhiteBalance(red: gains.x, green: gains.y, blue: gains.z)
    }
}
