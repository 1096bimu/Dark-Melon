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
    private let kernel = CIColorKernel(source: """
        float encodeLUT(float x, float profile) {
            if (profile < 0.5) {
                float v = abs(x);
                return sign(x) * (v <= 0.0031308 ? 12.92*v : 1.055*pow(v,1.0/2.4)-0.055);
            }
            if (profile < 1.5) {
                float v = abs(x);
                return sign(x) * (v < 0.018 ? 4.5*v : 1.099*pow(v,0.45)-0.099);
            }
            if (profile < 2.5) {
                return x >= 0.01125 ? (420.0+261.5*log((x+0.01)/0.19)/log(10.0))/1023.0
                    : (x*(171.2102946929-95.0)/0.01125+95.0)/1023.0;
            }
            if (profile < 3.5) {
                return x < 0.01 ? 5.6*x+0.125 : 0.241514*log(x+0.00873)/log(10.0)+0.598206;
            }
            if (profile < 4.5) {
                float v = x/0.9;
                if (v < -0.014) return -0.36726845*log(1.0-14.98325*v)/log(10.0)+0.12783901;
                if (v <= 0.014) return 1.9754798*v+0.12512219;
                return 0.36726845*log(1.0+14.98325*v)/log(10.0)+0.12240537;
            }
            if (profile < 5.5) {
                return x >= 0.00089 ? 0.344676*log(0.555556*x+0.009468)/log(10.0)+0.790453
                    : 8.735631*x+0.092864;
            }
            return x >= 0.000889 ? 0.245281*log(5.555556*x+0.064829)/log(10.0)+0.384316
                : 8.799461*x+0.092864;
        }
        float decodeLUT(float x, float profile) {
            if (profile < 0.5) {
                float v = abs(x);
                return sign(x) * (v <= 0.04045 ? v/12.92 : pow((v+0.055)/1.055,2.4));
            }
            if (profile < 1.5) {
                float v = abs(x);
                return sign(x) * (v < 0.081 ? v/4.5 : pow((v+0.099)/1.099,1.0/0.45));
            }
            if (profile < 2.5) {
                return x >= 171.2102946929/1023.0 ? pow(10.0,(x*1023.0-420.0)/261.5)*0.19-0.01
                    : (x*1023.0-95.0)*0.01125/(171.2102946929-95.0);
            }
            if (profile < 3.5) {
                return x < 0.181 ? (x-0.125)/5.6 : pow(10.0,(x-0.598206)/0.241514)-0.00873;
            }
            if (profile < 4.5) {
                if (x < 0.097465473) return -0.9*(pow(10.0,(0.12783901-x)/0.36726845)-1.0)/14.98325;
                if (x <= 0.15277891) return 0.9*(x-0.12512219)/1.9754798;
                return 0.9*(pow(10.0,(x-0.12240537)/0.36726845)-1.0)/14.98325;
            }
            if (profile < 5.5) {
                return x >= 0.100537775223865 ? (pow(10.0,(x-0.790453)/0.344676)-0.009468)/0.555556
                    : (x-0.092864)/8.735631;
            }
            return x >= 0.100686685370811 ? (pow(10.0,(x-0.384316)/0.245281)-0.064829)/5.555556
                : (x-0.092864)/8.799461;
        }
        kernel vec4 lutProfile(__sample source, vec3 row0, vec3 row1, vec3 row2, float profile, float decodeMode) {
            vec4 p = unpremultiply(source);
            vec3 c = p.rgb;
            if (decodeMode > 0.5) c = vec3(decodeLUT(c.r,profile),decodeLUT(c.g,profile),decodeLUT(c.b,profile));
            c = vec3(dot(row0,c),dot(row1,c),dot(row2,c));
            if (decodeMode < 0.5) c = vec3(encodeLUT(c.r,profile),encodeLUT(c.g,profile),encodeLUT(c.b,profile));
            return premultiply(vec4(c,p.a));
        }
        """)

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
