import Foundation
@testable import Dark_Melon

@main struct FolderRestoreChecks {
    @MainActor static func main() async throws {
        let key = "browser.lastFolderBookmarks"
        let original = UserDefaults.standard.data(forKey: key)
        defer {
            if let original { UserDefaults.standard.set(original, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let child = root.appendingPathComponent("Photos")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ImageBrowserModel(remembersFolder: true)
        model.choose(root)
        model.navigate(to: child)
        for _ in 0..<100 {
            if UserDefaults.standard.data(forKey: key) != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(UserDefaults.standard.data(forKey: key) != nil)
        let restored = ImageBrowserModel(remembersFolder: true)
        restored.restoreLastFolder()
        for _ in 0..<250 {
            if restored.directory != nil && !restored.loading { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(restored.root?.standardizedFileURL == root.standardizedFileURL)
        precondition(restored.directory?.standardizedFileURL == child.standardizedFileURL)
        precondition(!restored.loading && restored.error == nil)
        let manual = ImageBrowserModel(remembersFolder: true)
        manual.restoreLastFolder()
        manual.choose(root)
        try await Task.sleep(for: .milliseconds(250))
        precondition(manual.directory?.standardizedFileURL == root.standardizedFileURL)
        UserDefaults.standard.set(try PropertyListEncoder().encode([Data(), Data()]), forKey: key)
        let broken = ImageBrowserModel(remembersFolder: true)
        broken.restoreLastFolder()
        try await Task.sleep(for: .milliseconds(250))
        precondition(broken.directory == nil && !broken.loading && broken.error == nil)
        print("PASS: persisted root/current folder, local restoration, manual navigation wins, invalid bookmarks open empty")
    }
}
