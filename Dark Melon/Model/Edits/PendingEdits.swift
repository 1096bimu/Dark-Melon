import Foundation

nonisolated struct PendingEdits {
    struct Entry: Identifiable {
        let url: URL
        var recipe: DevelopmentRecipe
        let baseline: DevelopmentRecipe
        let savedRecipe: DevelopmentRecipe?
        var modifiedAt = Date()
        var session: SnapshotSession? = nil
        var id: URL { url }
    }
    private(set) var entries: [Entry] = []
    func entry(for url: URL) -> Entry? {
        let key = url.standardizedFileURL
        return entries.first { $0.url == key }
    }
    mutating func remember(url: URL, recipe: DevelopmentRecipe, baseline: DevelopmentRecipe, saved: DevelopmentRecipe?, session: SnapshotSession? = nil) {
        let url = url.standardizedFileURL
        guard recipe != baseline else { remove(url); return }
        var entry = Entry(url: url, recipe: recipe, baseline: baseline, savedRecipe: saved)
        entry.session = session
        if let previous = self.entry(for: url), previous.recipe == recipe { entry.modifiedAt = previous.modifiedAt }
        if let index = entries.firstIndex(where: { $0.url == url }) { entries[index] = entry }
        else { entries.append(entry) }
    }
    mutating func remove(_ url: URL) {
        let key = url.standardizedFileURL
        entries.removeAll { $0.url == key }
    }
    mutating func clear() { entries.removeAll() }
}
