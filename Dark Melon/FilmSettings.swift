import SwiftUI

extension EnvironmentValues {
    @Entry var lockedFilmItems: Set<PasteItem> = []
}

private struct FilmLock: ViewModifier {
    let item: PasteItem
    @Environment(\.lockedFilmItems) private var items
    func body(content: Content) -> some View { content.disabled(items.contains(item)) }
}
extension View {
    func filmLock(_ item: PasteItem) -> some View { modifier(FilmLock(item: item)) }
}

/// A session-only capture, shared by the editor and all export paths.
nonisolated struct FilmSettings: Sendable {
    static let film = SettingsPasteSelection(items: [.contrast, .contrastDistribution, .rawWhiteBalance, .chromaCurve, .lightnessChromaCurve,
        .vertices, .hueTwister, .dyeResponse, .grain, .halation, .lut])
    static let digital = SettingsPasteSelection(items: film.selectedItems.subtracting([.rawWhiteBalance, .chromaCurve]).union([.rgbWhiteBalance, .clarity]))
    static func restoredSelection(_ saved: SettingsPasteSelection) -> SettingsPasteSelection {
        for preset in [film, digital] {
            if saved.selectedItems == preset.selectedItems.union([.whitePoint, .tone]) { return preset }
        }
        return saved
    }
    let selection: SettingsPasteSelection
    private let captured: ToneMapping
    private let rawSettings: RAWSettings?

    init(_ mapping: ToneMapping, rawSettings: RAWSettings? = nil, selection: SettingsPasteSelection = Self.film) {
        captured = mapping
        self.rawSettings = rawSettings
        self.selection = selection
    }
    func applying(to mapping: ToneMapping) -> ToneMapping {
        selection.applying(captured, to: mapping)
    }
    func applyingRAW(to settings: RAWSettings?) -> RAWSettings? {
        selection.applyingRAW(rawSettings, to: settings)
    }
    func applying(to recipe: DevelopmentRecipe) -> DevelopmentRecipe {
        var result = recipe
        result.mapping = applying(to: recipe.mapping)
        if recipe.mapping.rawWhiteBalance != nil { result.rawSettings = applyingRAW(to: recipe.rawSettings) }
        return result
    }
}
