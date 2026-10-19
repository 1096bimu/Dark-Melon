import CoreGraphics

nonisolated enum ProcessingColorSpace: String, Codable, CaseIterable, Identifiable, Sendable {
    case sRGB = "sRGB"
    case displayP3 = "Display P3"
    case rec2020 = "Rec.2020"

    var id: Self { self }
    var linear: CGColorSpace {
        switch self {
        case .sRGB: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        case .displayP3: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        case .rec2020: CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
        }
    }
    var encoded: CGColorSpace {
        switch self {
        case .sRGB: CGColorSpace(name: CGColorSpace.sRGB)!
        case .displayP3: CGColorSpace(name: CGColorSpace.displayP3)!
        case .rec2020: CGColorSpace(name: CGColorSpace.itur_2020)!
        }
    }
    /// Choose by the embedded profile's gamut, not by colors present in this photo.
    static func covering(_ source: CGColorSpace?) -> Self {
        guard let source else { return .sRGB }
        if source == CGColorSpaceCreateDeviceRGB() { return .sRGB }
        if source.model == .monochrome { return .sRGB }
        guard source.model == .rgb else { return .rec2020 }
        // Extended destinations preserve negative coordinates: a negative channel
        // means this source primary lies outside the candidate's RGB gamut.
        for candidate in [Self.sRGB, .displayP3] {
            let containsPrimaries = (0..<3).allSatisfy { channel in
                var components: [CGFloat] = [0, 0, 0, 1]
                components[channel] = 1
                guard let color = CGColor(colorSpace: source, components: components),
                      let converted = color.converted(to: candidate.linear,
                        intent: .relativeColorimetric, options: nil)?.components else { return false }
                let rgb = converted.prefix(3)
                let magnitude = max(1e-9, rgb.map { abs($0) }.max() ?? 0)
                return rgb.allSatisfy { $0.isFinite && $0 / magnitude >= -0.001 }
            }
            if containsPrimaries { return candidate }
        }
        // Widest available option, also used for profiles beyond our supported gamut.
        return .rec2020
    }

    var luminance: SIMD3<Double> {
        switch self {
        case .sRGB: SIMD3(0.2126, 0.7152, 0.0722)
        case .displayP3: SIMD3(0.2289746, 0.6917385, 0.0792869)
        case .rec2020: SIMD3(0.2627, 0.6780, 0.0593)
        }
    }
}
