import Foundation
@testable import Dark_Melon

@main struct SnapshotChecks {
    @MainActor static func main() async throws {
        let saved = DevelopmentRecipe(colorSpace: .sRGB, mapping: ToneMapping())
        var draft = saved
        draft.mapping.concentration = 0.4
        var replacement = saved
        replacement.mapping.concentration = 0.6
        var session = SnapshotSession(selected: "unsaved", draft: SnapshotEdit(draft))
        var displayed = draft
        let history = EditHistory()
        history.captureSession = { session }
        history.restoreSession = { session = $0 }
        history.restore = { displayed = $0 }
        let url = URL(fileURLWithPath: "/tmp/snapshot-test.jpg")
        history.activate(url, recipe: displayed)
        // Switch to saved, retaining the draft.
        session.selected = "saved"
        displayed = saved
        history.observe(displayed, name: "Switch Snapshot"); history.flush()
        history.undo()
        assert(displayed == draft && session.selected == "unsaved")
        history.redo()
        assert(displayed == saved && session.draft == SnapshotEdit(draft))
        // Editing the saved state replaces the draft; undo restores both branches.
        displayed = replacement
        session = SnapshotSession(selected: "unsaved", draft: SnapshotEdit(replacement))
        history.observe(displayed); history.flush()
        history.undo()
        assert(displayed == saved && session.selected == "saved" && session.draft == SnapshotEdit(draft))
        history.redo()
        assert(displayed == replacement && session.draft == SnapshotEdit(replacement))
        var recipe = replacement
        recipe.snapshots = [NamedSnapshot(name: "Warm", edit: SnapshotEdit(draft))]
        let decoded = try DevelopmentRecipe.decode(recipe.encoded())
        assert(decoded == recipe)
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".jpg")
        defer { try? FileManager.default.removeItem(at: RecipeStore.sidecarURL(for: file)) }
        let stored = try RecipeStore.shared.saveSynchronously(recipe, for: file)
        assert(stored.snapshots == recipe.snapshots)
        let loaded = try await RecipeStore.shared.load(for: file)
        assert(loaded == recipe)
        var old = try JSONSerialization.jsonObject(with: saved.encoded()) as! [String: Any]
        old.removeValue(forKey: "snapshots")
        let migrated = try DevelopmentRecipe.decode(JSONSerialization.data(withJSONObject: old))
        assert(migrated.snapshots.isEmpty)
        print("Snapshot switching/replacement undo-redo, recipe roundtrip, sidecar write, and old recipe defaults passed.")
    }
}
