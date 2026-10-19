import CoreGraphics
import Foundation
import simd

/// CIELAB, D50 reference white. a* points right, b* up; radius one = 128 Lab units.
/// RGB/XYZ and Bradford adaptation follow W3C CSS Color 4 conversion conventions.
nonisolated enum ScopeProjection {
    static let radius = 128.0

    static func matrix(_ space: ProcessingColorSpace) -> simd_double3x3 {
        let rgb: simd_double3x3
        switch space {
        case .sRGB:
            rgb = .init(columns: (SIMD3(0.4123907993,0.2126390059,0.0193308187),
                                  SIMD3(0.3575843394,0.7151686788,0.1191947798),
                                  SIMD3(0.1804807884,0.0721923154,0.9505321522)))
        case .displayP3:
            rgb = .init(columns: (SIMD3(0.4865709486,0.2289745641,0),
                                  SIMD3(0.2656676932,0.6917385218,0.0451133819),
                                  SIMD3(0.1982172852,0.0792869141,1.0439443689)))
        case .rec2020:
            rgb = .init(columns: (SIMD3(0.6369580483,0.2627002120,0),
                                  SIMD3(0.1446169036,0.6779980715,0.0280726930),
                                  SIMD3(0.1688809752,0.0593017165,1.0609850577)))
        }
        let adaptation = simd_double3x3(rows: [
            SIMD3(1.0479297925,0.0229468706,-0.0501922663),
            SIMD3(0.0296278088,0.9904344268,-0.0170737991),
            SIMD3(-0.0092430582,0.0150551449,0.7518742814)])
        let xyz = adaptation * rgb
        let white = xyz * SIMD3(repeating: 1)
        return .init(columns: (xyz.columns.0 / white, xyz.columns.1 / white, xyz.columns.2 / white))
    }

    static func lab(_ linear: SIMD3<Double>, space: ProcessingColorSpace) -> SIMD3<Double> {
        let xyz = matrix(space) * linear
        func f(_ t: Double) -> Double { t > 216.0/24389 ? cbrt(t) : (24389.0/27 * t + 16)/116 }
        let v = SIMD3(f(xyz.x), f(xyz.y), f(xyz.z))
        return SIMD3(116*v.y - 16, 500*(v.x-v.y), 200*(v.y-v.z))
    }

    static func linear(_ lab: SIMD3<Double>, space: ProcessingColorSpace) -> SIMD3<Double> {
        let fy = (lab.x + 16)/116
        func f(_ t: Double) -> Double { t > 6.0/29 ? t*t*t : (116*t-16)/(24389.0/27) }
        return matrix(space).inverse * SIMD3(f(fy+lab.y/500), f(fy), f(fy-lab.z/200))
    }

    static func point(r: Double, g: Double, b: Double, space: ProcessingColorSpace = .sRGB) -> CGPoint {
        func decode(_ x: Double) -> Double {
            if space == .rec2020 {
                return x < 0.0812428583 ? x/4.5 : pow((x+0.0992968268)/1.0992968268, 1/0.45)
            }
            return x <= 0.04045 ? x/12.92 : pow((x+0.055)/1.055, 2.4)
        }
        let value = lab(SIMD3(decode(r), decode(g), decode(b)), space: space)
        return CGPoint(x: value.y/radius, y: -value.z/radius)
    }

    /// Minimal a/b projection to the allowed half-plane, retaining Lab lightness.
    /// If the target is outside positive RGB, desaturate toward neutral at the same L.
    static func correctedBalance(sample: SIMD3<Double>, balance: WhiteBalance,
                                 space: ProcessingColorSpace) -> WhiteBalance {
        let gains = SIMD3(balance.red, balance.green, balance.blue)
        let current = sample * gains
        guard min(current.x,current.y,current.z) > 1e-8 else { return balance }
        var target = lab(current, space: space)
        guard target.y + target.z < -0.0001 else { return balance }
        let shift = (target.y + target.z)/2
        target.y -= shift; target.z -= shift
        var desired = linear(target, space: space)
        for _ in 0..<32 {
            if min(desired.x,desired.y,desired.z) > 1e-8 { break }
            target.y *= 0.8; target.z *= 0.8
            desired = linear(target, space: space)
        }
        let result = desired / sample
        guard result.x.isFinite, result.y.isFinite, result.z.isFinite else { return balance }
        return WhiteBalance(red: result.x, green: result.y, blue: result.z)
    }
}
