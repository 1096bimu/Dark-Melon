import Foundation
@testable import Dark_Melon

@main struct MultipleLUTImportChecks {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LUTStore(directory: root.appendingPathComponent("LUTs"))
        let libraryURL = root.appendingPathComponent("library.json")
        let library = EditLibrary(url: libraryURL, lutStore: store)
        library.addFolder("Test Folder",parent: nil)
        let parent = library.entries.first!.id
        var text = "LUT_3D_SIZE 2\n"
        for b in 0...1 { for g in 0...1 { for r in 0...1 { text += "\(r) \(g) \(b)\n" } } }
        let first = root.appendingPathComponent("First.cube"), last = root.appendingPathComponent("Last.cube")
        let bad = root.appendingPathComponent("Broken.cube")
        for source in [first,last] { try text.write(to: source,atomically: true,encoding: .utf8) }
        try "Not a cube".write(to: bad,atomically: true,encoding: .utf8)
        await library.addLUTs([first,bad,last],parent: parent)
        let entries = library.entries.filter { $0.lutID != nil }
        assert(entries.map(\.name) == ["First","Last"])
        assert(entries.allSatisfy { $0.parent == parent })
        assert(library.error?.contains("Broken.cube") == true)
        assert(!library.importingLUT)
        assert(Set(entries.compactMap(\.lutID)).count == 2)
        for id in entries.compactMap(\.lutID) { assert(store.cube(for: id)?.dimension == 2) }
        let reopened = EditLibrary(url: libraryURL,lutStore: store)
        assert(reopened.entries.compactMap(\.lutID) == entries.compactMap(\.lutID))
        await library.addLUTs([],parent: parent)
        assert(library.entries.count == 3)
        library.remove(parent)
        assert(library.entries.isEmpty)
        for id in entries.compactMap(\.lutID) { assert(store.cube(for: id) == nil) }
        print("PASS: multiple LUT import, invalid-file continuation, folder placement, unique copies, persistence, empty selection and removal")
    }
}
