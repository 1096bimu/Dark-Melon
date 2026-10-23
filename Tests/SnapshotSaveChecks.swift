import Foundation
@testable import Dark_Melon

@main struct SnapshotSaveChecks {
    @MainActor static func main() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        defer { try? FileManager.default.removeItem(at: RecipeStore.sidecarURL(for:file)) }
        var original = DevelopmentRecipe(colorSpace:.displayP3,mapping:ToneMapping())
        original.mapping.concentration = 0.2
        var unsaved = original
        unsaved.mapping.concentration = 0.6
        let date = Date(timeIntervalSinceReferenceDate:12345)
        var session = SnapshotSession(selected:"saved",draft:SnapshotEdit(unsaved),draftModifiedAt:date)
        var current = original
        current.draftSnapshot = session.persistedDraft
        let savedOriginal = session.recipeForSaving(current)
        assert(savedOriginal.mapping.concentration == 0.2)
        assert(savedOriginal.draftSnapshot?.edit.mapping.concentration == 0.6)
        _ = try RecipeStore.shared.saveSynchronously(savedOriginal,for:file)
        let reopened = try await RecipeStore.shared.load(for:file)!
        assert(reopened == savedOriginal && reopened.draftSnapshot?.modifiedAt == date)
        session.didSave(savedOriginal)
        assert(session.selected == "saved" && session.draft == SnapshotEdit(unsaved))

        // Save All must keep the selected recipe, even when another draft is present.
        var pending = PendingEdits()
        pending.remember(url:file,recipe:current,baseline:original,saved:original,session:session)
        let entry = pending.entry(for:file)!
        let batchSaved = entry.session!.recipeForSaving(entry.recipe)
        assert(batchSaved.mapping.concentration == 0.2 && batchSaved.draftSnapshot != nil)

        // Selecting the draft commits that state as primary and removes only its duplicate.
        session.selected = "unsaved"
        current = unsaved
        current.draftSnapshot = session.persistedDraft
        let committed = session.recipeForSaving(current)
        assert(committed.mapping.concentration == 0.6 && committed.draftSnapshot == nil)
        session.didSave(committed)
        assert(session.selected == "saved" && session.draft == nil)

        // A named state saves as primary while retaining a different draft.
        session = SnapshotSession(selected:UUID().uuidString,draft:SnapshotEdit(unsaved),draftModifiedAt:date)
        var named = original
        named.mapping.concentration = 0.4
        let savedNamed = session.recipeForSaving(named)
        assert(savedNamed.mapping.concentration == 0.4 && savedNamed.draftSnapshot?.edit == SnapshotEdit(unsaved))
        let decoded = try DevelopmentRecipe.decode(savedNamed.encoded())
        assert(decoded == savedNamed)

        let history = EditHistory()
        var displayed = original
        var state = SnapshotSession(selected:"saved",draft:SnapshotEdit(unsaved))
        history.captureSession = { state }
        history.restoreSession = { state = $0 }
        history.restore = { displayed = $0 }
        history.activate(file,recipe:displayed)
        state.selected = "unsaved"; displayed = unsaved
        history.observe(displayed,name:"Switch Snapshot"); history.flush()
        history.undo()
        assert(displayed.mapping.concentration == 0.2 && state.selected == "saved")
        let afterUndo = state.recipeForSaving(displayed)
        assert(afterUndo.mapping.concentration == 0.2 && afterUndo.draftSnapshot?.edit.mapping.concentration == 0.6)
        print("Saving selected Saved/Unsaved/named states, Save All, draft persistence, timestamps and undo passed.")
    }
}
