import Foundation
import ImageIO
@testable import Dark_Melon

@main struct LegacyRecipeMigrationChecks {
    @MainActor static func main() async throws {
        var original = DevelopmentRecipe(colorSpace: .displayP3, mapping: ToneMapping())
        precondition(FilmGrainSettings().output == .additive)
        precondition(ToneMapping.fresh(isRAW: false, sourceHeadroom: 1).grain.output == .additive)
        original.mapping.grain.output = .filmDensity
        original.mapping.channelContrast = [0.15, -0.1, 0.05]
        original.mapping.dyePurity = [0.8, 0.7, 0.9]
        original.mapping.dyeMixers.a[1] = 0.1
        original.mapping.white = 0.73
        original.mapping.concentration = 0.37
        original.mapping.whiteBalance.red = 1.2
        let current = try JSONSerialization.jsonObject(with: original.encoded()) as! [String: Any]
        func legacy(_ source: [String: Any], distribution: Any, grain: [String: Any]) -> [String: Any] {
            var result = source
            var mapping = result["mapping"] as! [String: Any]
            mapping["contrastDistribution"] = distribution
            mapping["storedShadowFloor"] = 0.1
            mapping["storedShadowFloorCode"] = 128
            mapping["grain"] = grain
            result["mapping"] = mapping
            return result
        }
        let oldGrain: [String: Any] = ["size": 0.5, "strength": 0.8, "distribution": 0.9]
        var old = legacy(current, distribution: [-2.0, 1, -1, 2], grain: oldGrain)
        var expected = original; expected.mapping.grain.strength = 0.8
        let restored = try DevelopmentRecipe.decode(JSONSerialization.data(withJSONObject: old))
        precondition(restored == expected, "Only grain amount is inherited; unrelated edits remain intact")
        let direct = try JSONDecoder().decode(FilmGrainSettings.self, from: JSONSerialization.data(withJSONObject: oldGrain))
        var directExpected = expected.mapping.grain; directExpected.output = .additive
        precondition(direct == directExpected)
        // Discard retired fields without attempting to decode their obsolete types.
        let malformed = legacy(current, distribution: "retired", grain: ["size": "retired", "distribution": "retired", "strength": 0.8])
        precondition(tryDecode(malformed) == expected)
        for distribution: Any in [["black": -1.0, "width": 0.2, "white": -1.0], ["black": 2.0, "centerRange": 0.8, "white": 2.0], [0.0, -1.0, 1.0, 0.0]] {
            var transitional = old
            var mapping = transitional["mapping"] as! [String: Any]
            mapping["storedContrastDistribution"] = distribution
            transitional["mapping"] = mapping
            precondition(tryDecode(transitional) == expected)
        }
        // Nested snapshots and drafts must receive the same migration.
        var edit = old; edit.removeValue(forKey: "version")
        old["snapshots"] = [["id": UUID().uuidString, "name": "Legacy", "edit": edit]]
        old["draftSnapshot"] = ["edit": edit]
        let nested = try DevelopmentRecipe.decode(JSONSerialization.data(withJSONObject: old))
        precondition(nested.snapshots.first?.edit.mapping == expected.mapping)
        precondition(nested.draftSnapshot?.edit.mapping == expected.mapping)
        let saved = try JSONSerialization.jsonObject(with: nested.encoded()) as! [String: Any]
        let savedMapping = saved["mapping"] as! [String: Any]
        precondition(savedMapping["contrastDistribution"] == nil)
        precondition(savedMapping["storedShadowFloor"] == nil && savedMapping["storedShadowFloorCode"] == nil)
        let savedGrain = savedMapping["grain"] as! [String: Any]
        precondition(savedGrain["distribution"] == nil && savedGrain["size"] as? Double == 2)
        let repeated = try DevelopmentRecipe.decode(nested.encoded())
        precondition(repeated == nested, "Migration must be idempotent")
        // The immediately preceding schema has Offset/Color Scale but no mode.
        var prior = current
        var priorMapping = prior["mapping"] as! [String: Any]
        var priorGrain = priorMapping["grain"] as! [String: Any]
        priorGrain.removeValue(forKey: "output")
        priorMapping["grain"] = priorGrain; prior["mapping"] = priorMapping
        precondition(tryDecode(prior) == original, "Missing mode must retain dye settings in Analogue")
        // No explicit mode: only meaningful legacy dye settings select Analogue.
        let cleanRecipe = DevelopmentRecipe(colorSpace: .sRGB, mapping: ToneMapping())
        let cleanDocument = try JSONSerialization.jsonObject(with: cleanRecipe.encoded()) as! [String: Any]
        for kind in 0..<5 {
            var document = cleanDocument
            var mapping = document["mapping"] as! [String: Any]
            mapping["grain"] = ["strength": 0.0]
            if kind == 1 { mapping["channelContrast"] = [0.1,-0.1,0] }
            if kind == 2 { mapping["storedDyePurity"] = [0.9,1,1] }
            if kind == 3 { mapping["dyeMixers"] = ["a":[1.0,0.1,0,0,1,0,0,0,1],"b":DyeMixers.identity] }
            if kind == 4 { mapping["channelContrast"] = [0.1,0.1,0.1] }
            document["mapping"] = mapping
            let decoded = try DevelopmentRecipe.decode(JSONSerialization.data(withJSONObject: document))
            precondition(decoded.mapping.grain.output == ((kind == 0 || kind == 4) ? .additive:.filmDensity))
        }
        // Current edits must not be reset by legacy migration.
        var modern = original
        modern.mapping.grain.output = .additive
        modern.mapping.grain.size = 6.5; modern.mapping.grain.strength = 1.7
        modern.mapping.grain.offset = -0.4; modern.mapping.grain.colorScale = 0.9
        modern.mapping.contrastDistribution = ToneContrastDistribution(black: 0.3, shadowWidth: 0.2, highlightWidth: 0.7, white: 0.4)
        let modernRestored = try DevelopmentRecipe.decode(modern.encoded())
        precondition(modernRestored == modern)
        for invalidValue in [-0.1, 8.1] {
            var invalid = modern; invalid.mapping.grain.size = invalidValue
            do { _ = try DevelopmentRecipe.decode(invalid.encoded()); fatalError("Invalid modern grain size accepted") }
            catch RecipeError.invalid { }
        }
        // Exercise the XMP sidecar reader with old-format JSON, without
        // writing to any user's image or saved settings.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let imageURL = folder.appendingPathComponent("legacy.png")
        let metadata = CGImageMetadataCreateMutable()
        precondition(CGImageMetadataRegisterNamespaceForPrefix(metadata, "urn:dark-melon:development:1.0/" as CFString, "darkmelon" as CFString, nil))
        let oldJSON = String(data: try JSONSerialization.data(withJSONObject: old), encoding: .utf8)!
        precondition(CGImageMetadataSetValueWithPath(metadata, nil, "darkmelon:Recipe" as CFString, oldJSON as CFString))
        try (CGImageMetadataCreateXMPData(metadata, nil)! as Data).write(to: RecipeStore.sidecarURL(for: imageURL))
        let sidecar = try await RecipeStore.shared.load(for: imageURL)
        precondition(sidecar == nested)
        // Verify the same reader used for library presets and sidecars, read-only.
        var checked = 0
        for path in CommandLine.arguments.dropFirst() {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let entries = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
            let copy = folder.appendingPathComponent(UUID().uuidString + ".json")
            try data.write(to: copy)
            let suite = "LegacyRecipeMigrationChecks-" + UUID().uuidString
            let preferences = UserDefaults(suiteName: suite)!
            let library = EditLibrary(url: copy, lutStore: LUTStore(directory: folder.appendingPathComponent("LUTs")), preferences: preferences)
            precondition(library.error == nil && library.entries.count == entries.count)
            preferences.removePersistentDomain(forName: suite)
            for entry in entries {
                guard let recipe = entry["recipe"] as? [String: Any] else { continue }
                _ = try DevelopmentRecipe.decode(JSONSerialization.data(withJSONObject: recipe))
                checked += 1
            }
        }
        print("PASS: retired contrast/floor discarded, grain amount inherited unchanged, defaults restored, snapshots/drafts migrated, current settings preserved, \(checked) saved presets decoded read-only")
    }
    static func tryDecode(_ document: [String: Any]) -> DevelopmentRecipe {
        try! DevelopmentRecipe.decode(JSONSerialization.data(withJSONObject: document))
    }
}
