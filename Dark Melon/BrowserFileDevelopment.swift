import Foundation

enum BrowserFileAction { case deleteEdit, showInFinder, copyEdit, pasteEdit, export }

/// Independent preparation keeps file-menu operations from changing the active editor.
struct BrowserFileDevelopment {
    let development: RAWDevelopment
    let recipe: DevelopmentRecipe
    let worker: RAWDeveloper
    let savedRecipe: DevelopmentRecipe?

    static func load(_ url: URL, override: DevelopmentRecipe? = nil, bins: Int, film: FilmSettings? = nil) async throws -> Self {
        let saved = try await RecipeStore.shared.load(for: url)
        let restored = override ?? saved
        let space: ProcessingColorSpace
        if let restored { space = restored.colorSpace }
        else { space = try await RAWDeveloper().suggestedColorSpace(for: url) }
        var recipe = restored ?? DevelopmentRecipe(colorSpace: space, mapping: .fresh(isRAW: false, sourceHeadroom: 1))
        if restored == nil {
            let target = try await BrowserRecipeTarget.fresh(url)
            let resolver = RAWDeveloper(colorSpace: space)
            recipe = try await resolver.resolveExportRecipe(url, recipe: target.recipe, isRAW: target.isRAW,
                maximizeRange: UserDefaults.standard.bool(forKey: RAWSettings.maximizeRangePreferenceKey))
            if target.isRAW, let defaults = EditLibrary.shared.rawDefaultPreset { recipe = defaults.applying(to: recipe) }
        }
        var worker = RAWDeveloper(colorSpace: space, rawSettings: recipe.rawSettings, rawWhiteBalance: recipe.mapping.rawWhiteBalance)
        var development = try await worker.develop(url)
        if development.isRAW, recipe.mapping.rawWhiteBalance == nil, let reference = development.whitePoint {
            recipe.mapping.rawWhiteBalance = RAWWhiteBalance(reference)
        }
        if let defaults = development.rawDefaults {
            recipe.rawSettings = recipe.rawSettings?.resolved(using: defaults) ?? defaults
        }
        if let film {
            let updated = film.applying(to: recipe)
            if updated.rawSettings != recipe.rawSettings || updated.mapping.rawWhiteBalance != recipe.mapping.rawWhiteBalance {
                worker = RAWDeveloper(colorSpace: space, rawSettings: updated.rawSettings, rawWhiteBalance: updated.mapping.rawWhiteBalance)
                development = try await worker.develop(url)
            }
            recipe = updated
        }
        return Self(development: development, recipe: recipe, worker: worker, savedRecipe: saved)
    }
}
