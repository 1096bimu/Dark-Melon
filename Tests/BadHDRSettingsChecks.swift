import Foundation
@testable import Dark_Melon

@main struct BadHDRSettingsChecks {
    @MainActor static func main() async throws {
        let clean = DevelopmentRecipe(colorSpace: .displayP3,
                                      mapping: .fresh(isRAW: true, sourceHeadroom: 1))
        var edited = clean
        edited.mapping.badHDR = BadHDRSettings(strength: -1.75, radius: 2.25)
        let roundtrip = try DevelopmentRecipe.decode(edited.encoded())
        assert(roundtrip == edited)

        var legacy = try JSONSerialization.jsonObject(with: edited.encoded()) as! [String: Any]
        var mapping = legacy["mapping"] as! [String: Any]
        mapping.removeValue(forKey: "badHDR")
        legacy["mapping"] = mapping
        let old = try DevelopmentRecipe.decode(JSONSerialization.data(withJSONObject: legacy))
        assert(old.mapping.badHDR == BadHDRSettings(), "Old edits must default to Off")
        mapping["badHDR"] = ["strength": -0.5]
        legacy["mapping"] = mapping
        let partial = try DevelopmentRecipe.decode(JSONSerialization.data(withJSONObject: legacy))
        assert(partial.mapping.badHDR == BadHDRSettings(strength: -0.5))
        for invalid in [BadHDRSettings(strength: 16.01), BadHDRSettings(strength: -16.01), BadHDRSettings(radius: -0.01), BadHDRSettings(radius: 32.01)] {
            var recipe = clean; recipe.mapping.badHDR = invalid
            do { _ = try DevelopmentRecipe.decode(recipe.encoded()); fatalError("Invalid effect accepted") }
            catch RecipeError.invalid { }
        }

        let selection = SettingsPasteSelection(items: [.badHDR])
        assert(PasteItem.effectItems.last == .badHDR)
        let copy = try CopiedSettings.decode(CopiedSettings.encode(edited, reference: nil))
        assert(selection.applying(copy.mapping, to: clean.mapping) == edited.mapping)
        assert(SettingsPasteSelection(effects: false).applying(copy.mapping, to: clean.mapping) == clean.mapping)
        assert(SettingsPasteSelection().applying(copy.mapping, to: clean.mapping) == edited.mapping)
        let selectionRoundtrip = try JSONDecoder().decode(SettingsPasteSelection.self, from: JSONEncoder().encode(selection))
        assert(selectionRoundtrip == selection)

        let film = FilmSettings(edited.mapping, selection: selection)
        assert(film.applying(to: clean) == edited)
        let preset = RAWDefaultPreset(recipe: edited, selection: selection)
        assert(preset.applying(to: clean) == edited)
        let defaults = EditorDefaultsCache()
        let resolved = defaults.resolve(space: .displayP3, isRAW: true, headroom: 1, raw: nil, balance: nil, preset: preset)
        assert(resolved.mapping.badHDR == edited.mapping.badHDR)

        let history = EditHistory()
        let file = URL(fileURLWithPath: "/tmp/badhdr-history.dng")
        var restored: DevelopmentRecipe?
        history.restore = { restored = $0 }
        history.activate(file, recipe: clean)
        history.observe(edited); history.flush()
        assert(EditHistory.actionName(from: clean, to: edited) == String(localized: "Effects"))
        history.undo(); assert(restored == clean)
        history.redo(); assert(restored == edited)
        history.clear()
        var pending = PendingEdits()
        pending.remember(url: file, recipe: edited, baseline: clean, saved: clean)
        assert(pending.entry(for: file)?.recipe == edited)

        var snapshots = edited
        snapshots.snapshots = [NamedSnapshot(name: "BadHDR", edit: SnapshotEdit(edited))]
        snapshots.draftSnapshot = DraftSnapshot(edit: SnapshotEdit(edited), modifiedAt: Date())
        let snapshotRoundtrip = try DevelopmentRecipe.decode(snapshots.encoded())
        assert(snapshotRoundtrip == snapshots)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("test.dng")
        try await RecipeStore.shared.save(snapshots, for: source)
        let saved = try await RecipeStore.shared.load(for: source)
        assert(saved == snapshots)
        print("PASS: BadHDR legacy/new/partial recipes, validation, clipboard, selective paste, Film Lock, RAW defaults, undo/redo, pending edits, snapshots and XMP save/load")
    }
}
