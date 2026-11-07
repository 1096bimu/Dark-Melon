import Foundation
@testable import Dark_Melon

@main struct BundledPresetChecks {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "BundledPresetChecks-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: root)
            preferences.removePersistentDomain(forName: suite)
        }
        let source = URL(fileURLWithPath: "Dark Melon/Resources/BundledPresets.json")
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: source)) as! [String: Any]
        let bundled = try JSONDecoder().decode([LibraryEntry].self,
            from: JSONSerialization.data(withJSONObject: manifest["entries"]!))
        let folder = bundled.first(where: \.isFolder)!
        assert(bundled.count == 9 && bundled.filter { $0.recipe != nil }.count == 8)
        assert(bundled.allSatisfy { $0.lutID == nil })
        let freshURL = root.appendingPathComponent("fresh.json")
        func open(_ url: URL) -> EditLibrary {
            EditLibrary(url: url, preferences: preferences, bundledPresetsURL: source)
        }
        let fresh = open(freshURL)
        assert(fresh.error == nil && fresh.entries.count == 9)
        assert(fresh.entries.filter { $0.recipe != nil }.allSatisfy { $0.parent == folder.id && $0.selection != nil })
        assert(open(freshURL).entries.count == 9)
        fresh.remove(folder.id)
        assert(open(freshURL).entries.isEmpty) // Intentional deletion stays deleted.

        let existingURL = root.appendingPathComponent("existing.json")
        let userEdit = LibraryEntry(name: "My own preset", recipe: bundled.first { $0.recipe != nil }!.recipe,
                                    selection: SettingsPasteSelection())
        let userLUT = LibraryEntry(name: "Imported LUT", lutID: UUID())
        let retiredID = UUID(uuidString: (manifest["retiredLUTEntries"] as! [String])[0])!
        let retired = LibraryEntry(id: retiredID, name: "Old bundled LUT", lutID: UUID())
        var renamed = folder; renamed.name = "My films"
        try JSONEncoder().encode([userEdit, userLUT, retired, renamed]).write(to: existingURL)
        let upgraded = open(existingURL)
        assert(upgraded.error == nil && upgraded.entries.count == 11)
        assert(upgraded.entries.contains { $0.id == userEdit.id })
        assert(upgraded.entries.contains { $0.id == userLUT.id })
        assert(!upgraded.entries.contains { $0.id == retiredID })
        assert(upgraded.entries.first { $0.id == folder.id }?.name == "My films")
        assert(open(existingURL).entries.count == 11)

        let brokenURL = root.appendingPathComponent("broken.json")
        let broken = Data("broken".utf8)
        try broken.write(to: brokenURL)
        assert(open(brokenURL).error != nil)
        let preserved = try Data(contentsOf: brokenURL)
        assert(preserved == broken)
        try FileManager.default.removeItem(at: brokenURL)
        assert(open(brokenURL).entries.count == 9) // Failed load didn't mark installation complete.
        print("PASS: bundled presets, fresh install, upgrade, preserved user entries, deduplication, deletion and corrupt-library protection")
    }
}
