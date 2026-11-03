#if os(macOS)
import AppKit

/// Folder grants cover both existing sidecars and creation of new sidecars.
@MainActor final class SidecarFolderAccess {
    static let shared = SidecarFolderAccess()
    private let key = "sidecarFolderBookmarks.v1"
    private var grants: [URL] = []
    private var verified: Set<URL> = []

    private init() {
        var refreshed: [Data] = []
        for data in UserDefaults.standard.array(forKey: key) as? [Data] ?? [] {
            do {
                var stale = false
                let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                                  relativeTo: nil, bookmarkDataIsStale: &stale)
                guard url.startAccessingSecurityScopedResource() else { continue }
                grants.append(url)
                refreshed.append(stale ? try url.bookmarkData(options: .withSecurityScope,
                    includingResourceValuesForKeys: nil, relativeTo: nil) : data)
            } catch { continue }
        }
        UserDefaults.standard.set(refreshed, forKey: key)
    }

    @discardableResult
    func requestIfNeeded(for image: URL) -> Bool {
        let folder = image.deletingLastPathComponent().standardizedFileURL
        if verified.contains(folder) { return true }
        // Unlike fileExists, directory enumeration distinguishes denied access
        // from an absent sidecar. The browser may already hold a folder grant.
        if (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) != nil,
           FileManager.default.isWritableFile(atPath: folder.path) {
            verified.insert(folder)
            return true
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Allow access to this image’s folder?")
        alert.informativeText = String(localized: "Dark Melon needs access to \(folder.lastPathComponent) to read and save the image’s edit sidecar. Select that folder once to remember access for future sessions. Opening only the image does not grant access to its sidecar.")
        alert.addButton(withTitle: String(localized: "Allow Access to Containing Folder…"))
        alert.addButton(withTitle: String(localized: "Continue Without Access"))
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        let panel = NSOpenPanel()
        panel.title = String(localized: "Allow Sidecar Folder Access")
        panel.message = String(localized: "Select \(folder.lastPathComponent), the folder containing \(image.lastPathComponent).")
        panel.prompt = String(localized: "Allow Access")
        panel.directoryURL = folder
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, let selected = panel.url else { return false }
        guard selected.resolvingSymlinksInPath().standardizedFileURL == folder.resolvingSymlinksInPath() else {
            let error = NSAlert()
            error.messageText = String(localized: "Select the image’s containing folder.")
            error.informativeText = String(localized: "Access to a different folder does not allow reading or saving this image’s sidecar.")
            error.runModal()
            return false
        }
        let scoped = selected.startAccessingSecurityScopedResource()
        do {
            let bookmark = try selected.bookmarkData(options: .withSecurityScope,
                includingResourceValuesForKeys: nil, relativeTo: nil)
            var saved = UserDefaults.standard.array(forKey: key) as? [Data] ?? []
            saved.append(bookmark)
            UserDefaults.standard.set(saved, forKey: key)
            if scoped { grants.append(selected) }
            verified.insert(folder)
            return true
        } catch {
            if scoped { selected.stopAccessingSecurityScopedResource() }
            NSAlert(error: error).runModal()
            return false
        }
    }
}
#endif
