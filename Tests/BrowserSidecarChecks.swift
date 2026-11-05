import Foundation
@testable import Dark_Melon

@main struct BrowserSidecarChecks {
    @MainActor static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("first.jpg")
        let second = folder.appendingPathComponent("second.jpg")
        for url in [first, second] { try Data().write(to: url) }
        let recipe = DevelopmentRecipe(colorSpace: .sRGB, mapping: ToneMapping())

        func waitFor(_ condition: () -> Bool) async throws {
            for _ in 0..<200 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            preconditionFailure("Browser did not reflect the sidecar change")
        }

        // No browser view exists: saves must still update the retained model.
        let model = ImageBrowserModel()
        model.choose(folder)
        try await waitFor { !model.loading }
        precondition(model.error == nil && model.entries.count == 2)
        model.filter = .edited
        precondition(model.visibleFiles.isEmpty)
        _ = try RecipeStore.shared.saveSynchronously(recipe, for: first)
        try await waitFor { model.visibleFiles.map(\.url) == [first] }
        let revision = model.listingRevision
        model.pendingURLs = [second]
        try await RecipeStore.shared.save(recipe, for: second)
        try await waitFor { model.entries.allSatisfy(\.hasSavedSettings) }
        precondition(model.listingRevision == revision, "Saving should preserve the current listing")
        precondition(model.filter == .edited && model.pendingURLs == [second])

        try await RecipeStore.shared.delete(for: first)
        try await waitFor { model.visibleFiles.map(\.url) == [second] }
        try await RecipeStore.shared.delete(for: second)
        try await waitFor { model.entries.allSatisfy { !$0.hasSavedSettings } }
        precondition(model.visibleFiles.map(\.url) == [second], "Pending edits must remain visible")
        model.pendingURLs = []
        precondition(model.visibleFiles.isEmpty)

        // Reconcile notifications delivered while a folder is being listed.
        model.navigate(to: folder)
        _ = try RecipeStore.shared.saveSynchronously(recipe, for: first)
        try await waitFor { !model.loading && model.visibleFiles.map(\.url) == [first] }
        precondition(model.entries.first { $0.url == second }?.hasSavedSettings == false)
        print("PASS: hidden-browser save/delete updates, synchronous and actor saves, Edited filter, pending edits, stable listing and save during navigation")
    }
}
