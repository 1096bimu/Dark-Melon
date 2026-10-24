import CoreImage
import Foundation
import ImageIO
@testable import Dark_Melon

@main struct FilmExportChecks {
    @MainActor static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let output = folder.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let context = CIContext()
        let source = CIImage(color: CIColor(red: 0.15, green: 0.35, blue: 0.65))
            .cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
        let files = ["saved", "fresh"].map { folder.appendingPathComponent($0 + ".png") }
        for file in files {
            try context.writePNGRepresentation(of: source, to: file, format: .RGBA8, colorSpace: ProcessingColorSpace.sRGB.encoded)
        }
        var saved = ToneMapping(); saved.concentration = 0; saved.hdrGain = 0
        try await RecipeStore.shared.save(DevelopmentRecipe(colorSpace: .sRGB, mapping: saved), for: files[0])
        let sidecar = RecipeStore.sidecarURL(for: files[0])
        let originalData = try Data(contentsOf: sidecar)
        var capture = ToneMapping(); capture.concentration = 0.65
        let lock = FilmSettings(capture, selection: SettingsPasteSelection(items: [.contrast]))
        var settings = HEIFSettings(); settings.format = .jpeg; settings.quality = 1
        var failures: [String] = []
        let prepared = try await ExportPlan.prepare(files: files, film: lock, maximizeRAWRange: false) { _, _ in }
        let plan = ExportPlan(items: prepared.items, settings: settings, failures: prepared.failures)
        await BatchExportRunner.run(plan: plan, destination: output) { result, _ in
            if let error = result.error { failures.append(error) }
        }
        assert(failures.isEmpty, "Batch failed: \(failures)")
        func pixels(_ data: Data) -> Data {
            let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(data as CFData, nil)!, 0, nil)!
            return image.dataProvider!.data! as Data
        }
        for file in files {
            let prepared = try await BrowserFileDevelopment.load(file, bins: 128, film: lock)
            assert(prepared.recipe.mapping.concentration == capture.concentration)
            let expected = try await prepared.worker.exportHEIF(file, mapping: prepared.recipe.mapping, settings: settings)
            let actual = try Data(contentsOf: output.appendingPathComponent(file.deletingPathExtension().lastPathComponent + ".jpg"))
            assert(pixels(expected) == pixels(actual))
        }
        let after = try Data(contentsOf: sidecar)
        assert(originalData == after)
        assert(!FileManager.default.fileExists(atPath: RecipeStore.sidecarURL(for: files[1]).path))
        print("PASS: locked single/context and concurrent batch exports agree for saved and fresh files; sidecars unchanged")
    }
}
