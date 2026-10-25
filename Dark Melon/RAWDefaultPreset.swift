import SwiftUI

/// An immutable selection, also captured by export preparation before background work.
nonisolated struct RAWDefaultPreset: Sendable, Equatable {
    let recipe: DevelopmentRecipe
    let selection: SettingsPasteSelection

    func applying(to fallback: DevelopmentRecipe) -> DevelopmentRecipe {
        var result = fallback
        result.mapping = selection.applying(recipe.mapping, to: fallback.mapping)
        result.rawSettings = selection.applyingRAW(recipe.rawSettings, to: fallback.rawSettings)
        return result
    }
}

extension EnvironmentValues {
    @Entry var resetMapping = ToneMapping()
}

/// Memoized by actual default inputs, never by viewport or hover state.
final class EditorDefaultsCache {
    private struct Key: Equatable {
        let space: ProcessingColorSpace
        let isRAW: Bool
        let headroom: Double
        let raw: RAWSettings?
        let balance: RAWWhiteBalance?
        let preset: RAWDefaultPreset?
    }
    private var key: Key?
    private var recipe: DevelopmentRecipe?

    func resolve(space: ProcessingColorSpace, isRAW: Bool, headroom: Double,
                 raw: RAWSettings?, balance: RAWWhiteBalance?, preset: RAWDefaultPreset?) -> DevelopmentRecipe {
        let next = Key(space: space, isRAW: isRAW, headroom: headroom, raw: raw,
                       balance: balance, preset: isRAW ? preset : nil)
        if key == next, let recipe { return recipe }
        var result = DevelopmentRecipe(colorSpace: space,
            mapping: .fresh(isRAW: isRAW, sourceHeadroom: headroom), rawSettings: raw)
        result.mapping.rawWhiteBalance = balance
        if let preset = next.preset { result = preset.applying(to: result) }
        key = next
        recipe = result
        return result
    }
}
