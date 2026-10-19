import Foundation

nonisolated struct PendingEdits {
    struct Entry: Identifiable {
        let url: URL
        var recipe: DevelopmentRecipe
        let baseline: DevelopmentRecipe
        let savedRecipe: DevelopmentRecipe?
        var id: URL { url }
    }
    private(set) var entries: [Entry] = []
    func entry(for url: URL) -> Entry? { entries.first { $0.url == url.standardizedFileURL } }
    mutating func remember(url: URL, recipe: DevelopmentRecipe, baseline: DevelopmentRecipe, saved: DevelopmentRecipe?) {
        let url = url.standardizedFileURL
        guard recipe != baseline else { remove(url); return }
        let entry = Entry(url: url, recipe: recipe, baseline: baseline, savedRecipe: saved)
        if let index = entries.firstIndex(where: { $0.url == url }) { entries[index] = entry }
        else { entries.append(entry) }
    }
    mutating func remove(_ url: URL) { entries.removeAll { $0.url == url.standardizedFileURL } }
    mutating func clear() { entries.removeAll() }
}
