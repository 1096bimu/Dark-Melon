import CoreImage
import Foundation
import simd

/// Bundled gamma/gamut choices, using full-range normalized LUT coordinates.
nonisolated enum LUTProfile: String, CaseIterable, Codable, Identifiable, Sendable {
    case sRGB, rec709, sLog3, vLog, cLog3, fLog, fLog2
    static let outputChoices: [Self] = [.sRGB, .rec709]
    var id: Self { self }
    var isLog: Bool { self == .sLog3 || self == .vLog || self == .cLog3 || self == .fLog || self == .fLog2 }
    var name: String {
        switch self {
        case .sRGB: "sRGB"
        case .rec709: "Rec.709 (BT.709)"
        case .sLog3: "Sony S-Log3 / S-Gamut3.Cine"
        case .vLog: "Panasonic V-Log / V-Gamut"
        case .cLog3: "Canon C-Log3 / Cinema Gamut"
        case .fLog: "Fujifilm F-Log / F-Gamut"
        case .fLog2: "Fujifilm F-Log2 / Rec.2020"
        }
    }
    var code: Double { Double(Self.allCases.firstIndex(of: self)!) }

    // D65 primaries and transfer equations follow the vendor-supplied ACES CSCs:
    // https://github.com/aces-aswf/aces-input-and-colorspaces (Sony, Panasonic, Canon).
    // F-Log / F-Gamut: https://dl.fujifilm-x.com/technical-data/F-Log_DataSheet_E_Ver.1.2.pdf
    // F-Log2 / Rec.2020: https://dl.fujifilm-x.com/support/lut/F-Log2_DataSheet_E_Ver.1.0.pdf
    var toXYZ: simd_double3x3 {
        let points: [SIMD2<Double>]
        switch self {
        case .sRGB, .rec709: points = [.init(0.64, 0.33), .init(0.30, 0.60), .init(0.15, 0.06)]
        case .sLog3: points = [.init(0.766, 0.275), .init(0.225, 0.800), .init(0.089, -0.087)]
        case .vLog: points = [.init(0.730, 0.280), .init(0.165, 0.840), .init(0.100, -0.030)]
        case .cLog3: points = [.init(0.740, 0.270), .init(0.170, 1.140), .init(0.080, -0.100)]
        case .fLog, .fLog2: points = [.init(0.708, 0.292), .init(0.170, 0.797), .init(0.131, 0.046)]
        }
        func xyz(_ xy: SIMD2<Double>) -> SIMD3<Double> { .init(xy.x / xy.y, 1, (1 - xy.x - xy.y) / xy.y) }
        let matrix = simd_double3x3(columns: (xyz(points[0]), xyz(points[1]), xyz(points[2])))
        let scale = matrix.inverse * xyz(.init(0.3127, 0.3290))
        return simd_double3x3(columns: (matrix[0] * scale.x, matrix[1] * scale.y, matrix[2] * scale.z))
    }
}

nonisolated struct LUTConfiguration: Codable, Equatable, Sendable {
    var input = LUTProfile.sRGB
    var output = LUTProfile.sRGB
}

nonisolated final class LUTProfileTransform {
    private static let linearSRGB = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private let kernel = MetalImageKernels.color("lutProfile")

    func encode(_ image: CIImage, profile: LUTProfile) throws -> CIImage {
        guard let linear = image.matchedFromWorkingSpace(to: Self.linearSRGB) else { throw LUTError.invalid }
        return try apply(linear, profile: profile, inverse: false)
    }
    func decode(_ image: CIImage, profile: LUTProfile) throws -> CIImage {
        let linear = try apply(image, profile: profile, inverse: true)
        guard let output = linear.matchedToWorkingSpace(from: Self.linearSRGB) else { throw LUTError.invalid }
        return output
    }
    private func apply(_ image: CIImage, profile: LUTProfile, inverse: Bool) throws -> CIImage {
        let matrix = inverse ? LUTProfile.sRGB.toXYZ.inverse * profile.toXYZ : profile.toXYZ.inverse * LUTProfile.sRGB.toXYZ
        func row(_ index: Int) -> CIVector { CIVector(x: matrix[0][index], y: matrix[1][index], z: matrix[2][index]) }
        guard let output = kernel?.apply(extent: image.extent, arguments: [image, row(0), row(1), row(2), profile.code, inverse ? 1.0 : 0.0]) else { throw LUTError.invalid }
        return output
    }
}
