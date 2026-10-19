import Foundation

/// A portable, versioned recipe for the original source, not a rendered export.
/// RAW decoder settings and transient UI/compare state intentionally stay out.
nonisolated struct DevelopmentRecipe: Codable, Equatable, Sendable {
    var version = 1
    var colorSpace: ProcessingColorSpace
    var mapping: ToneMapping

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 256 * 1024,
              let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = document["version"] as? Int, version == 1 else {
            throw RecipeError.unsupported
        }
        // Missing fields inherit current defaults; unknown fields are ignored by Codable.
        // This allows additive controls without invalidating existing recipes.
        let defaults = try JSONSerialization.jsonObject(with: Self(colorSpace: .sRGB, mapping: ToneMapping()).encoded()) as! [String: Any]
        func merged(_ base: [String: Any], _ edits: [String: Any]) -> [String: Any] {
            var result = base
            for (key, value) in edits {
                if let child = value as? [String: Any], let fallback = base[key] as? [String: Any] {
                    result[key] = merged(fallback, child)
                } else { result[key] = value }
            }
            return result
        }
        let result = try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: merged(defaults, document)))
        try result.validate()
        return result
    }

    private func validate() throws {
        let m = mapping
        func within(_ value: Double, _ range: ClosedRange<Double>) -> Bool { value.isFinite && range.contains(value) }
        guard m.hls.count == 6,
              within(m.black, 0...1), within(m.white, 0...1), m.white - m.black >= ToneMapping.minimumRange * 0.999,
              within(m.tonePosition, 0...1), within(m.concentration, -1...1),
              within(m.hdrMax, 1...20), within(m.hdrConcentrationOffset, -2...2),
              within(m.clarity, -2...2), within(m.clarityRadius, 15...90),
              within(m.hdf, 0...0.2), within(m.hdfRadius, 50...200),
              within(m.grain.size, 0.2...3), within(m.grain.strength, 0...5), within(m.grain.distribution, 0...1),
              [m.whiteBalance.red, m.whiteBalance.green, m.whiteBalance.blue].allSatisfy({ within($0, 0.000001...10000) }),
              (0..<5).allSatisfy({ within(m.blackAndWhite.value(at: $0), 0...2) }),
              m.hls.allSatisfy({ within($0.shadowHue, -30...30) && within($0.midtoneHue, -30...30) && within($0.highlightHue, -30...30) && within($0.saturation, 0...2) && within($0.lightness, -1...1) }),
              [m.color.saturationStart, m.color.saturationEnd, m.color.luminanceSaturationStart, m.color.luminanceSaturationEnd].allSatisfy({ within($0, 0...2) }),
              [m.color.saturationCurve, m.color.luminanceSaturationCurve, m.color.splitTone.amountCurveA].allSatisfy({ within($0, -8...8) }),
              within(m.color.splitTone.shadowHue, 0...360), within(m.color.splitTone.highlightHue, 0...360),
              within(m.color.splitTone.shadowAmount, 0...2), within(m.color.splitTone.highlightAmount, 0...2),
              m.color.splitTone.midpointRadius.map({ within($0, 0...1) }) ?? true
        else { throw RecipeError.invalid }
    }
}

nonisolated enum RecipeError: LocalizedError {
    case unsupported, invalid
    var errorDescription: String? {
        switch self {
        case .unsupported: "This development recipe uses an unsupported version or is too large."
        case .invalid: "The saved development settings contain invalid values."
        }
    }
}
