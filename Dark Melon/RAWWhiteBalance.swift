import CoreImage

/// Persisted decoder white balance; other RAW controls remain session-only.
nonisolated struct RAWWhiteBalance: Codable, Equatable, Sendable {
    var temperature: Float
    var tint: Float

    init(_ reference: RAWWhitePoint) {
        temperature = Float(reference.temperature)
        tint = Float(reference.tint)
    }
    static func asShot(_ source: URL) throws -> Self {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        guard let raw = CIRAWFilter(imageURL: source),
              let reference = RAWWhitePoint(chromaticity: raw.neutralChromaticity,
                                            temperature: Double(raw.neutralTemperature), tint: Double(raw.neutralTint))
        else { throw RecipeError.invalid }
        return Self(reference)
    }

    func apply(to raw: CIRAWFilter) {
        raw.neutralTemperature = temperature
        raw.neutralTint = tint
    }

    static func baked(_ recipe: DevelopmentRecipe, source: URL) throws -> DevelopmentRecipe {
        guard let balance = recipe.mapping.rawWhiteBalance,
              recipe.mapping.whiteBalance != WhiteBalance() else { return recipe }
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        guard let raw = CIRAWFilter(imageURL: source) else { throw RecipeError.invalid }
        balance.apply(to: raw)
        guard let target = WhiteBalanceTarget(gains: recipe.mapping.whiteBalance,
                                               reference: raw.neutralChromaticity, space: recipe.colorSpace)
        else { throw RecipeError.invalid }
        raw.neutralChromaticity = CGPoint(x: target.x, y: target.y)
        var result = recipe
        var baked = balance
        baked.temperature = min(10000, max(2000, raw.neutralTemperature))
        baked.tint = min(50, max(-50, raw.neutralTint))
        guard baked.temperature.isFinite, baked.tint.isFinite else { throw RecipeError.invalid }
        result.mapping.rawWhiteBalance = baked
        result.mapping.whiteBalance = WhiteBalance()
        return result
    }
}
