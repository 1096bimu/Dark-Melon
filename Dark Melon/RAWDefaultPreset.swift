import SwiftUI

/// An immutable selection, also captured by export preparation before background work.
nonisolated struct RAWDefaultPreset: Sendable {
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
