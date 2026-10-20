import Foundation

enum BrowserFileAction { case deleteEdit, showInFinder, copyEdit, pasteEdit, export }

/// Independent preparation keeps file-menu operations from changing the active editor.
struct BrowserFileDevelopment {
    let development: RAWDevelopment
    let recipe: DevelopmentRecipe
    let worker: RAWDeveloper
    let savedRecipe: DevelopmentRecipe?

    static func load(_ url: URL, override: DevelopmentRecipe? = nil, bins: Int) async throws -> Self {
        let saved = try await RecipeStore.shared.load(for: url)
        let restored = override ?? saved
        let space: ProcessingColorSpace
        if let restored { space = restored.colorSpace }
        else { space = try await RAWDeveloper().suggestedColorSpace(for: url) }
        let worker = RAWDeveloper(colorSpace: space, rawSettings: restored?.rawSettings, rawWhiteBalance: restored?.mapping.rawWhiteBalance)
        let development = try await worker.develop(url)
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
            recipe.rawSettings = recipe.rawSettings?.resolved(using: defaults) ?? defaults
        }
        return Self(development: development, recipe: recipe, worker: worker, savedRecipe: saved)
    }
}
