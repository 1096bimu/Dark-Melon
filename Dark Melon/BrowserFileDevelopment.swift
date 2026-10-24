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
        var rawOptions = restored?.rawSettings
        var worker = RAWDeveloper(colorSpace: space, rawSettings: restored?.rawSettings, rawWhiteBalance: restored?.mapping.rawWhiteBalance)
        if restored == nil, let settings = try await worker.initialRAWSettings(url) {
            rawOptions = settings
            worker = RAWDeveloper(colorSpace: space, rawSettings: settings)
        }
        var development = try await worker.develop(url)
        var recipe: DevelopmentRecipe
        if let restored { recipe = restored }
        else {
            let mapping = try await worker.automaticMapping(for: development, bins: bins)
            recipe = DevelopmentRecipe(colorSpace: space, mapping: mapping)
        }
        if development.isRAW, recipe.mapping.rawWhiteBalance == nil, let reference = development.whitePoint {
            recipe.mapping.rawWhiteBalance = RAWWhiteBalance(reference)
        }
        if let defaults = development.rawDefaults {
            recipe.rawSettings = rawOptions?.resolved(using: defaults) ?? defaults
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
