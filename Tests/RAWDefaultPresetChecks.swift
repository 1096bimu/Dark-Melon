import Foundation
import CoreImage
@testable import Dark_Melon

@main struct RAWDefaultPresetChecks {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "RAWDefaultPresetChecks-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: root)
            preferences.removePersistentDomain(forName: suite)
        }
        let url = root.appendingPathComponent("library.json")
        let library = EditLibrary(url: url, preferences: preferences)
        library.addFolder("Defaults", parent: nil)
        let folder = library.entries[0].id
        var mapping = ToneMapping()
        mapping.concentration = 0.4
        mapping.white = 0.7
        mapping.grain.strength = 0.3
        var raw = RAWSettings()
        raw.values[.exposure] = -1
        raw.values[.shadowBias] = 0
        let recipe = DevelopmentRecipe(colorSpace: .sRGB, mapping: mapping, rawSettings: raw)
        let selection = SettingsPasteSelection(items: [.contrast, .grain, .exposure])
        library.addEdit("My film", parent: folder, recipe: recipe, selection: selection)
        let id = library.entries.last!.id
        library.useAsRAWDefault(id)
        let reopened = EditLibrary(url: url, preferences: preferences)
        assert(reopened.rawDefaultID == id)
        let preset = reopened.rawDefaultPreset!
        let fallback = DevelopmentRecipe(colorSpace: .displayP3,
            mapping: .fresh(isRAW: true, sourceHeadroom: 1), rawSettings: raw)
        let applied = preset.applying(to: fallback)
        assert(applied.mapping.concentration == 0.4)
        assert(applied.mapping.grain.strength == 0.3)
        assert(applied.mapping.white == 1) // Unselected preset value must not leak.
        assert(applied.mapping.tonePosition == 0.183)
        assert(applied.mapping.halation == fallback.mapping.halation)
        assert(applied.colorSpace == .displayP3)
        library.rename(id, to: "Renamed")
        assert(library.rawDefaultID == id)
        library.remove(folder)
        assert(library.rawDefaultID == nil && library.rawDefaultPreset == nil)
        assert(EditLibrary(url: url, preferences: preferences).rawDefaultID == nil)

        // Higher numeric HDR gains remain valid in recipes, independent of slider range.
        var hdr = DevelopmentRecipe(colorSpace: .displayP3, mapping: .fresh(isRAW: false, sourceHeadroom: 20))
        assert(hdr.mapping.hdrGain == 20 && hdr.mapping.concentration == 0)
        hdr = try DevelopmentRecipe.decode(hdr.encoded())
        assert(hdr.mapping.hdrGain == 20)

        let png = root.appendingPathComponent("SDR.png")
        try CIContext().writePNGRepresentation(of: CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2)),
            to: png, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let sdrPlan = try await ExportPlan.prepare(files: [png], film: nil, maximizeRAWRange: false, rawDefault: preset) { _, _ in }
        assert(sdrPlan.failures.isEmpty)
        assert(sdrPlan.items[0].recipe.mapping.concentration == 0)
        assert(sdrPlan.items[0].recipe.mapping.hdrGain == 0)
        assert(sdrPlan.items[0].recipe.mapping.grain.strength == 0)

        if CommandLine.arguments.count > 1 {
            let source = URL(fileURLWithPath: CommandLine.arguments[1])
            let file = root.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: source)
            let plan = try await ExportPlan.prepare(files: [file], film: nil, maximizeRAWRange: false, rawDefault: preset) { _, _ in }
            assert(plan.failures.isEmpty && plan.items.count == 1)
            let fresh = plan.items[0].recipe
            assert(fresh.mapping.concentration == 0.4 && fresh.mapping.grain.strength == 0.3)
            assert(fresh.rawSettings?.values[.exposure] == -1)
            assert(fresh.rawSettings?.values[.shadowBias] == 2) // Decoder fallback retained.
            assert(fresh.mapping.rawWhiteBalance != nil)
            var saved = fresh
            saved.mapping.concentration = 0.1
            saved.rawSettings?.values[.exposure] = 1
            try await RecipeStore.shared.save(saved, for: file)
            let restored = try await ExportPlan.prepare(files: [file], film: nil, maximizeRAWRange: false, rawDefault: preset) { _, _ in }
            assert(restored.items[0].recipe.mapping.concentration == 0.1)
            assert(restored.items[0].recipe.rawSettings?.values[.exposure] == 1)
        }
        print("PASS: partial RAW defaults, persistence, deletion fallback, saved-edit protection, fresh RAW export and HDR gain round-trip")
    }
}
