import CoreImage

/// Persisted decoder white balance.
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
        let reference = raw.neutralChromaticity
        let original = recipe.mapping.whiteBalance
        var target = WhiteBalanceTarget(gains: original, reference: reference, space: recipe.colorSpace)
        var limited = false
        if target == nil {
            // Extreme RGB gains may imply a nonphysical scene white. Find the
            // largest representable portion along the logarithmic gain path.
            var lower = 0.0, upper = 1.0
            target = WhiteBalanceTarget(gains: WhiteBalance(), reference: reference, space: recipe.colorSpace)
            for _ in 0..<40 {
                let fraction = (lower + upper) / 2
                let part = WhiteBalance(red: pow(original.red, fraction),
                                        green: pow(original.green, fraction), blue: pow(original.blue, fraction))
                if let candidate = WhiteBalanceTarget(gains: part, reference: reference, space: recipe.colorSpace) {
                    target = candidate; lower = fraction
                } else { upper = fraction }
            }
            limited = true
        }
        guard let target else { throw RecipeError.invalid }
        raw.neutralChromaticity = CGPoint(x: target.x, y: target.y)
        let requestedTemperature = raw.neutralTemperature
        let requestedTint = raw.neutralTint
        guard requestedTemperature.isFinite, requestedTint.isFinite else { throw RecipeError.invalid }
        var result = recipe
        var baked = balance
        baked.temperature = min(10000, max(2000, requestedTemperature))
        baked.tint = min(50, max(-50, requestedTint))
        limited = limited || baked.temperature != requestedTemperature || baked.tint != requestedTint
        baked.apply(to: raw)
        result.mapping.rawWhiteBalance = baked
        if limited {
            // Estimate the RGB portion consumed by the bounded decoder WB,
            // then keep the remaining multiplicative adjustment in RGB.
            guard let achieved = WhiteBalanceTarget(chromaticity: raw.neutralChromaticity),
                  let consumed = achieved.gains(reference: reference, space: recipe.colorSpace)
            else { throw RecipeError.invalid }
            let residual = WhiteBalance(red: original.red / consumed.red,
                                        green: original.green / consumed.green,
                                        blue: original.blue / consumed.blue)
            guard [residual.red, residual.green, residual.blue].allSatisfy({
                $0.isFinite && (0.000001...10000).contains($0)
            }) else { throw RecipeError.invalid }
            result.mapping.whiteBalance = residual
        } else {
            result.mapping.whiteBalance = WhiteBalance()
        }
        return result
    }
}
