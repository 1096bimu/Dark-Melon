#if os(macOS)
import AppKit
import Observation

/// Explicit opens only; ordinary browser navigation never calls this store.
@Observable @MainActor final class RecentOpenItems {
    static let shared = RecentOpenItems()
    struct Item: Codable, Identifiable {
        let url: URL
        let bookmark: Data?
        let folder: Bool
        var id: URL { url }
    }
    private static let key = "recentExplicitOpens"
    private(set) var items: [Item]
    private var access: [URL: URL] = [:]

    private init() {
        items = UserDefaults.standard.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([Item].self, from: $0) } ?? []
    }
    func record(_ url: URL, folder: Bool) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        let key = url.standardizedFileURL
        let previous = items.first { $0.id == key }
        items.removeAll { $0.id == key }
        items.insert(Item(url: key, bookmark: bookmark ?? previous?.bookmark, folder: folder), at: 0)
        if items.count > 20 { items.removeLast(items.count - 20) }
        persist()
    }
    func resolve(_ item: Item) throws -> URL {
        var stale = false
        let url = try item.bookmark.map {
            try URL(resolvingBookmarkData: $0, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        } ?? item.url
        if access[item.id] == nil, url.startAccessingSecurityScopedResource() { access[item.id] = url }
        return url
    }
    func clear() {
        items = []
        persist()
        // Active sources may still need these session grants; clearing the menu
        // must not revoke permission from the editor or a background export.
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}
#endif
