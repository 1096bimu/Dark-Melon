import Foundation
import CoreImage
@testable import Dark_Melon

@main struct GrainSizeDefaultsChecks {
    @MainActor static func main() async throws {
        precondition(AdjustmentLimits.grainSize == 1...8)
        for (short, expected) in [(500.0, 1.0), (2000, 1), (4000, 2), (8000, 4), (16000, 8), (24000, 8)] {
            for size in [CGSize(width: short, height: short*1.5), CGSize(width: short*1.5, height: short)] {
                let mapping = ToneMapping.fresh(isRAW: true, sourceHeadroom: 1, sourceSize: size)
                precondition(mapping.grain.size == expected)
                let sdr = ToneMapping.fresh(isRAW: false, sourceHeadroom: 1, sourceSize: size)
                precondition(sdr.grain.size == expected)
            }
        }
        precondition(FilmGrainSettings.defaultSize(for: nil) == 2)
        precondition(FilmGrainSettings.defaultSize(for: .zero) == 2)
        let cache = EditorDefaultsCache()
        for (short, expected) in [(2000.0, 1.0), (8000, 4), (4000, 2)] {
            let defaults = cache.resolve(space: .sRGB, isRAW: false, headroom: 1, raw: nil, balance: nil, preset: nil,
                sourceSize: CGSize(width: short*1.5, height: short))
            precondition(defaults.mapping.grain.size == expected, "Reset defaults must change with source dimensions")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("source.png")
        try CIContext().writePNGRepresentation(of: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 3000, height: 2000)),
            to: url, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let target = try await BrowserRecipeTarget.fresh(url)
        precondition(target.recipe.mapping.grain.size == 1)
        let plan = try await ExportPlan.prepare(files: [url], film: nil, maximizeRAWRange: false, rawDefault: nil) { _, _ in }
        precondition(plan.failures.isEmpty && plan.items.first?.recipe.mapping.grain.size == 1)
        var custom = target.recipe; custom.mapping.grain.size = 6.5
        try await RecipeStore.shared.save(custom, for: url)
        let restored = try await BrowserRecipeTarget.load(url)
        precondition(restored.recipe.mapping.grain.size == 6.5, "Saved user choice must survive reopening")
        let roundTrip = try DevelopmentRecipe.decode(custom.encoded())
        precondition(roundTrip.mapping.grain.size == 6.5)
        for bad in [0.9, 8.1] {
            var invalid = custom; invalid.mapping.grain.size = bad
            do { _ = try DevelopmentRecipe.decode(invalid.encoded()); fatalError("Invalid grain size accepted") }
            catch RecipeError.invalid { }
        }
        print("PASS: 1–8 range, proportional short-edge defaults, orientation, reset cache, fresh browser/export and preserved saved size")
    }
}
