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
        assert(decoded.snapshots[0].createdAt == recipe.snapshots[0].createdAt)
        var legacy = try JSONSerialization.jsonObject(with: recipe.encoded()) as! [String:Any]
        var snapshots = legacy["snapshots"] as! [[String:Any]]
        snapshots[0].removeValue(forKey: "createdAt")
        legacy["snapshots"] = snapshots
        let oldSnapshots = try DevelopmentRecipe.decode(JSONSerialization.data(withJSONObject:legacy))
        assert(oldSnapshots.snapshots[0].createdAt == nil)
        var pending = PendingEdits()
        pending.remember(url:file,recipe:draft,baseline:saved,saved:saved)
        let timestamp = pending.entry(for:file)!.modifiedAt
        pending.remember(url:file,recipe:draft,baseline:saved,saved:saved)
        assert(pending.entry(for:file)!.modifiedAt == timestamp)
        var calendar = Calendar(identifier:.gregorian)
        calendar.timeZone = TimeZone(identifier:"America/Toronto")!
        let now = calendar.date(from:DateComponents(year:2026,month:10,day:23,hour:12))!
        let yesterday = calendar.date(byAdding:.day,value:-1,to:now)!
        assert(SnapshotTimestamp.label(for:yesterday,now:now,calendar:calendar) == yesterday.formatted(date:.abbreviated,time:.omitted))
        assert(SnapshotTimestamp.label(for:now,now:now,calendar:calendar) == String(localized:"Just now"))
        print(SnapshotTimestamp.label(for:now.addingTimeInterval(-600),now:now,calendar:calendar))
        print(SnapshotTimestamp.label(for:now.addingTimeInterval(-7200),now:now,calendar:calendar))
        print("Snapshot switching/replacement undo-redo, recipe roundtrip, sidecar write, and old recipe defaults passed.")
    }
}
