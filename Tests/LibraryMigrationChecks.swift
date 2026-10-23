import Foundation
@testable import Dark_Melon

@main struct LibraryMigrationChecks {
    @MainActor static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("EditLibrary.json")
        let entry = LibraryEntry(name: "Old edit", recipe: DevelopmentRecipe(colorSpace: .sRGB, mapping: ToneMapping()), selection: SettingsPasteSelection())
        var items = try JSONSerialization.jsonObject(with: JSONEncoder().encode([entry])) as! [[String: Any]]
        var recipe = items[0]["recipe"] as! [String: Any]
        recipe.removeValue(forKey: "snapshots")
        var mapping = recipe["mapping"] as! [String: Any]
        mapping.removeValue(forKey: "channelContrast")
        recipe["mapping"] = mapping; items[0]["recipe"] = recipe
        try JSONSerialization.data(withJSONObject: items).write(to: url)
        let library = EditLibrary(url: url)
        assert(library.error == nil && library.entries.count == 1)
        assert(library.entries[0].recipe!.snapshots.isEmpty)
        assert(library.entries[0].recipe!.mapping.channelContrast == [0,0,0])
        library.addFolder("Folder", parent: nil)
        assert(EditLibrary(url: url).entries.count == 2)
        let broken = Data("broken data".utf8)
        try broken.write(to: url)
        let recovered = EditLibrary(url: url)
        assert(recovered.error != nil)
        recovered.addFolder("New", parent: nil)
        assert(EditLibrary(url: url).entries.count == 1)
        let backup = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first { $0.lastPathComponent.contains("backup-") }!
        let backupData = try Data(contentsOf: backup)
        assert(backupData == broken)
        let actual = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Containers/com.chengong.DarkMelon/Data/Library/Application Support/Dark Melon/EditLibrary.json")
        if FileManager.default.fileExists(atPath: actual.path) {
            let existing = EditLibrary(url: actual)
            assert(existing.error == nil && !existing.entries.isEmpty)
        }
        print("Old-library migration, subsequent saves, corrupt-library backup/recreation, and actual library loading passed.")
    }
}
