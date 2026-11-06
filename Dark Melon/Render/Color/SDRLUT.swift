import Foundation
import simd

/// The same encoded sRGB grid is used for visualization and .cube output.
nonisolated struct SDRLUT: Sendable {
    let dimension: Int
    let values: [SIMD3<Float>]

    static func pointwiseMapping(_ mapping: ToneMapping) -> ToneMapping {
        var settings = mapping
        settings.transform = nil
        settings.dustSpots = nil
        settings.chromaticAberration = ChromaticAberration()
        settings.hdf = 0
        settings.vignette.amount = 0
        settings.halation.inputCurve = 0
        // Exclude spatial texture, retaining the selected film/dye response.
        settings.grain.strength = 0
        settings.badHDR.strength = 0
        settings.clarity = 0
        return settings
    }

    func encoded() throws -> Data {
        let locale = Locale(identifier: "en_US_POSIX")
        var text = """
        TITLE "Dark Melon SDR"
        # Input: encoded sRGB. Output: encoded sRGB.
        # Spatial effects, crop and RAW decoder settings excluded.
        LUT_3D_SIZE \(dimension)
        DOMAIN_MIN 0 0 0
        DOMAIN_MAX 1 1 1

        """
        for rgb in values {
            try Task.checkCancellation()
            text += String(format: "%.7f %.7f %.7f\n", locale: locale, rgb.x, rgb.y, rgb.z)
        }
        return Data(text.utf8)
    }

    /// Encoded sRGB coordinates in the normalized 0–1 input domain.
    func sample(_ input: SIMD3<Float>) -> SIMD3<Float> {
        let p = simd_clamp(input, .zero, .one) * Float(dimension - 1)
        let lo = SIMD3<Int>(Int(p.x), Int(p.y), Int(p.z))
        let hi = simd_min(lo &+ SIMD3(repeating: 1), SIMD3(repeating: dimension - 1))
        let f = p - SIMD3(Float(lo.x), Float(lo.y), Float(lo.z))
        let a: Int, b: Int, c: Int
        if f.x >= f.y {
            if f.y >= f.z { (a, b, c) = (0, 1, 2) }
            else if f.x >= f.z { (a, b, c) = (0, 2, 1) }
            else { (a, b, c) = (2, 0, 1) }
        } else {
            if f.x >= f.z { (a, b, c) = (1, 0, 2) }
            else if f.y >= f.z { (a, b, c) = (1, 2, 0) }
            else { (a, b, c) = (2, 1, 0) }
        }
        func value(_ i: SIMD3<Int>) -> SIMD3<Float> { values[(i.z * dimension + i.y) * dimension + i.x] }
        var corner = lo
        let v0 = value(corner)
        corner[a] = hi[a]
        let v1 = value(corner)
        corner[b] = hi[b]
        let v2 = value(corner)
        return v0 * (1 - f[a]) + v1 * (f[a] - f[b]) + v2 * (f[b] - f[c]) + value(hi) * f[c]
    }
}
