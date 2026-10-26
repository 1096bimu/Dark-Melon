import Foundation

/// A portable, versioned recipe for the original source, not a rendered export.
/// Includes decoder adjustments; transient UI state stays out.
nonisolated struct DevelopmentRecipe: Codable, Equatable, Sendable {
    var version = 1
    var colorSpace: ProcessingColorSpace
    var mapping: ToneMapping
    var rawSettings: RAWSettings? = nil
    var snapshots: [NamedSnapshot] = []
    var draftSnapshot: DraftSnapshot? = nil

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 4 * 1024 * 1024,
              var document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = document["version"] as? Int, version == 1 else {
            throw RecipeError.unsupported
        }
        let draftSnapshot = document.removeValue(forKey: "draftSnapshot") as? [String: Any]
        let snapshots = document.removeValue(forKey: "snapshots") as? [[String: Any]] ?? []
        // Old HDR Gain was an endpoint, not a multiplier. Keep that endpoint
        // and use neutral gain; preserve the old Off state.
        if var mapping = document["mapping"] as? [String: Any],
           mapping["hdrTarget"] == nil, let old = mapping["hdrMax"] as? Double {
            mapping["hdrTarget"] = old
            mapping["hdrGain"] = old > 1 ? 1.0 : 0.0
            document["mapping"] = mapping
        }
        // Migrate the former Halation amount to the new input-curve control.
        if var mapping = document["mapping"] as? [String: Any],
           var halation = mapping["halation"] as? [String: Any] {
            if halation["inputCurve"] == nil, let strength = halation["strength"] {
                halation["inputCurve"] = strength
            }
            if let transmission = halation["transmission"] as? Double, transmission > 0.5, transmission <= 1 {
                halation["transmission"] = 0.5
            }
            mapping["halation"] = halation
            document["mapping"] = mapping
        }
        // Preserve the source shade selected by older, crop-range-relative Tone recipes.
        if var mapping = document["mapping"] as? [String: Any],
           mapping["toneUsesSourceLuminance"] as? Bool != true {
            if let tone = mapping["tonePosition"] as? Double {
                let black = mapping["black"] as? Double ?? 0
                let white = mapping["white"] as? Double ?? 1
                mapping["tonePosition"] = black + tone * (white - black)
            }
            mapping["toneUsesSourceLuminance"] = true
            document["mapping"] = mapping
        }
        if var mapping = document["mapping"] as? [String: Any],
           var color = mapping["color"] as? [String: Any] {
            for prefix in ["saturation", "luminanceSaturation"] {
                let start = color[prefix + "Start"] as? Double ?? 1
                let end = color[prefix + "End"] as? Double ?? 1
                if color[prefix + "Mid"] == nil {
                    let coefficient = color[prefix + "Curve"] as? Double ?? 0
                    color[prefix + "Mid"] = BoundedQuadraticCurve.value(at: 0.5, start: start, end: end,
                        coefficient: coefficient, outputRange: 0...2, curvatureScale: 1)
                }
                if color[prefix + "HDR"] == nil { color[prefix + "HDR"] = end }
            }
            if var split = color["splitTone"] as? [String: Any], split["nodes"] == nil {
                // Approximate the former hue/amount curve with three perceptual nodes.
                let legacy = try JSONDecoder().decode(SplitToneSettings.self, from: JSONSerialization.data(withJSONObject: split))
                let nodes: [SplitToneNode] = legacy.isIdentity ? [] : [0.0,0.5,1.0].map { t in
                    let point=legacy.huePoint(at:t)
                    let hue=(atan2(point.y,point.x)*180 / .pi+360).truncatingRemainder(dividingBy:360)
                    let amount=BoundedQuadraticCurve.value(at:t,start:legacy.shadowAmount,end:legacy.highlightAmount,
                        coefficient:legacy.amountCurveA,outputRange:0...2,curvatureScale:1)
                    return SplitToneNode(lightness:0.2+0.6*t,hue:hue,strength:min(1,amount/2))
                }
                split["nodes"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(nodes))
                color["splitTone"] = split
            }
            mapping["color"] = color
            document["mapping"] = mapping
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
        var result = try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: merged(defaults, document)))
        result.mapping.vertexWarp = OKLabVertexWarp.expanded(result.mapping.vertexWarp, space: result.colorSpace)
        // The former Monochrome button zeroed every node; expose that as On.
        let storedColor = (document["mapping"] as? [String: Any])?["color"] as? [String: Any]
        if storedColor?["monochrome"] == nil,
           result.mapping.vertexWarp.allSatisfy({ $0.chroma == 0 }) {
            result.mapping.color.monochrome = true
        }
        try result.validate()
        result.snapshots = try snapshots.map { item in
            guard let idString = item["id"] as? String, let id = UUID(uuidString: idString),
                  let name = item["name"] as? String, !name.isEmpty,
                  var edit = item["edit"] as? [String: Any] else { throw RecipeError.unsupported }
            edit["version"] = 1
            edit.removeValue(forKey: "snapshots")
            let validated = try Self.decode(JSONSerialization.data(withJSONObject: edit))
            let timestamp = item["createdAt"] as? Double
            guard timestamp?.isFinite != false else { throw RecipeError.unsupported }
            return NamedSnapshot(id: id, name: name, edit: SnapshotEdit(validated),
                createdAt: timestamp.map { Date(timeIntervalSinceReferenceDate: $0) })
        }
        guard Set(result.snapshots.map(\.id)).count == result.snapshots.count else { throw RecipeError.unsupported }
        if let draftSnapshot {
            guard var edit = draftSnapshot["edit"] as? [String: Any] else { throw RecipeError.unsupported }
            edit["version"] = 1
            edit.removeValue(forKey: "snapshots")
            edit.removeValue(forKey: "draftSnapshot")
            let validated = try Self.decode(JSONSerialization.data(withJSONObject: edit))
            let timestamp = draftSnapshot["modifiedAt"] as? Double
            guard timestamp?.isFinite != false else { throw RecipeError.unsupported }
            result.draftSnapshot = DraftSnapshot(edit: SnapshotEdit(validated),
                modifiedAt: timestamp.map { Date(timeIntervalSinceReferenceDate: $0) })
        }
        result.mapping.offset = result.mapping.offset.clamped(to: -0.02...0.02)
        // Preserve older recipes while bringing their multiplier into the current range.
        result.mapping.hdrGain = result.mapping.hdrGain == 0 ? 0 : max(1, result.mapping.hdrGain)
        return result
    }

    private func validate() throws {
        if let rawSettings {
            for (control, value) in rawSettings.values {
                guard value.isFinite, (control.minimum...control.maximum).contains(value) else { throw RecipeError.invalid }
            }
        }
        if let transform = mapping.transform, !transform.isValid { throw RecipeError.invalid }
        let m = mapping
        if let nodes = m.color.splitTone.nodes {
            guard nodes.count <= 6, Set(nodes.map(\.id)).count == nodes.count,
                  nodes.allSatisfy({ $0.lightness.isFinite && (0...5).contains($0.lightness) &&
                      $0.hue.isFinite && (0...360).contains($0.hue) && $0.strength.isFinite && (0...1).contains($0.strength) }) else { throw RecipeError.invalid }
        }
        func within(_ value: Double, _ range: ClosedRange<Double>) -> Bool { value.isFinite && range.contains(value) }
        if let wb = m.rawWhiteBalance {
            guard within(Double(wb.temperature), 2000...50000), within(Double(wb.tint), -150...150) else { throw RecipeError.invalid }
        }
        guard m.vertexWarp.count == OKLabVertexWarp.count,
              m.vertexWarp.allSatisfy({ within($0.darkerHue, -Double.pi...Double.pi) && within($0.lighterHue, -Double.pi...Double.pi) && within($0.chroma, 0...2) && within($0.lightness, -0.25...0.25) && within($0.rotation, -1...1) && ($0.hueOffset.map { within($0, -Double.pi...Double.pi) } ?? true) }),
              m.hls.count == 6,
              within(m.offset, -0.3...0.3), within(m.white, 0...1), m.white >= ToneMapping.minimumRange * 0.999,
              within(m.tonePosition, 0...1), within(m.concentration, -1...1),
              m.channelContrast.count == 3, m.channelContrast.allSatisfy({ within($0, -0.2...0.2) }),
              within(m.hdrRolloff, -1...1), within(m.hdrTarget, 1...20), m.hdrGain.isFinite, m.hdrGain >= 0,
              within(m.clarity, -2...2), within(m.clarityRadius, 15...90),
              within(m.hdf, 0...0.2), within(m.hdfRadius, 50...200),
              within(m.vignette.amount, 0...4), within(m.vignette.spread, 0...1),
              within(m.badHDR.strength, -4...4), within(m.badHDR.radius, 0.5...3),
              within(m.halation.inputCurve, 0...1), within(m.halation.radius, 0.5...3), within(m.halation.transmission, 0...0.5),
              within(m.grain.size, 0.2...3), within(m.grain.strength, 0...5), within(m.grain.distribution, 0...1),
              [m.whiteBalance.red, m.whiteBalance.green, m.whiteBalance.blue].allSatisfy({ within($0, 0.000001...10000) }),
              (0..<5).allSatisfy({ within(m.blackAndWhite.value(at: $0), 0...2) }),
              m.hls.allSatisfy({ within($0.shadowHue, -30...30) && within($0.midtoneHue, -30...30) && within($0.highlightHue, -30...30) && within($0.saturation, 0...2) && within($0.lightness, -1...1) }),
              [m.color.saturationStart, m.color.saturationEnd, m.color.luminanceSaturationStart, m.color.luminanceSaturationEnd, m.color.saturationMid, m.color.saturationHDR, m.color.luminanceSaturationMid, m.color.luminanceSaturationHDR].allSatisfy({ within($0, 0...2) }),
              [m.color.splitTone.amountCurveA].allSatisfy({ within($0, -8...8) }),
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
        case .unsupported: String(localized: "This development recipe uses an unsupported version or is too large.")
        case .invalid: String(localized: "The saved development settings contain invalid values.")
        }
    }
}
