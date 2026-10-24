import CoreImage
import Foundation
import ImageIO
@testable import Dark_Melon

@main struct ExportPlanChecks {
    @MainActor static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let output = folder.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let context = CIContext()
        let image = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 64, y: 64),
            "inputColor0": CIColor(red: 0.05, green: 0.1, blue: 0.2),
            "inputColor1": CIColor(red: 0.8, green: 0.6, blue: 0.4)
        ])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        let files = ["saved", "fresh"].map { folder.appendingPathComponent($0 + ".png") }
        for url in files {
            try context.writePNGRepresentation(of: image, to: url, format: .RGBA8, colorSpace: ProcessingColorSpace.sRGB.encoded)
        }
        var initial = ToneMapping(); initial.concentration = 0.1; initial.white = 0.8; initial.hdrGain = 0
        try await RecipeStore.shared.save(DevelopmentRecipe(colorSpace: .sRGB, mapping: initial), for: files[0])
        var film = ToneMapping(); film.concentration = 0.5
        var liveLock: FilmSettings? = FilmSettings(film, selection: SettingsPasteSelection(items: [.contrast]))
        let missing = folder.appendingPathComponent("missing.png")
        var preparationProgress: [Int] = []
        let prepared = try await ExportPlan.prepare(files: files + [missing], film: liveLock, maximizeRAWRange: false) { completed, total in
            assert(total == 3)
            preparationProgress.append(completed)
        }
        assert(prepared.items.map(\.source) == files && prepared.failures.count == 1)
        assert(preparationProgress == [1, 2, 3])
        let empty = try await ExportPlan.prepare(files: [], film: nil, maximizeRAWRange: false) { _, _ in assertionFailure() }
        assert(empty.items.isEmpty && empty.failures.isEmpty)
        let cancelledPreparation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ExportPlan.prepare(files: files, film: nil, maximizeRAWRange: false) { _, _ in }
        }
        do {
            _ = try await cancelledPreparation.value
            assertionFailure("Cancelled preparation should not return a partial plan")
        } catch is CancellationError {}
        var settings = HEIFSettings(); settings.format = .jpeg; settings.quality = 1
        let plan = ExportPlan(items: prepared.items, settings: settings, failures: prepared.failures)
        let frozen = try plan.items.map { try $0.recipe.encoded() }
        // Replace, add and then remove sidecars after preparation. Execution must
        // not consult any of these changes, a live lock, or export preferences.
        for url in files {
            var changed = ToneMapping(); changed.concentration = -0.8; changed.whiteBalance.red = 0.2
            try await RecipeStore.shared.save(DevelopmentRecipe(colorSpace: .rec2020, mapping: changed), for: url)
            try await RecipeStore.shared.delete(for: url)
        }
        liveLock = nil
        settings.quality = 0.1; settings.format = .tiff
        var errors: [String] = []
        await BatchExportRunner.run(plan: plan, destination: output) { result, _ in
            if let error = result.error { errors.append(error) }
        }
        assert(errors.isEmpty)
        func pixels(_ data: Data) -> Data {
            let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(data as CFData, nil)!, 0, nil)!
            return image.dataProvider!.data! as Data
        }
        for (index, item) in plan.items.enumerated() {
            let encoded = try item.recipe.encoded()
            assert(encoded == frozen[index])
            let recipe = item.recipe
            assert(recipe.mapping.concentration == 0.5)
            let worker = RAWDeveloper(colorSpace: recipe.colorSpace, rawSettings: recipe.rawSettings,
                                      rawWhiteBalance: recipe.mapping.rawWhiteBalance)
            let expected = try await worker.exportHEIF(item.source, mapping: recipe.mapping, settings: plan.settings)
            let actual = try Data(contentsOf: output.appendingPathComponent(item.source.deletingPathExtension().lastPathComponent + ".jpg"))
            assert(pixels(expected) == pixels(actual))
        }
        // A single export keeps its options-session worker/cache and survives
        // sidecar/source changes. Cancelling a queued job does not cancel it.
        let item = plan.items[0]
        let single = ExportPlan(items: [item], settings: plan.settings)
        let worker = RAWDeveloper(colorSpace: item.recipe.colorSpace, rawSettings: item.recipe.rawSettings)
        let bytes = try await worker.cachedExport(item.source, mapping: item.recipe.mapping, settings: single.settings)
        try FileManager.default.removeItem(at: item.source)
        let queue = ExportQueue()
        let destination = folder.appendingPathComponent("single.jpg")
        queue.enqueue(single, destination: .file(destination), cachedWorker: worker)
        let first = queue.jobs[0]
        queue.enqueue(single, destination: .file(folder.appendingPathComponent("cancelled.jpg")), cachedWorker: worker)
        let cancelled = queue.jobs[1]
        queue.cancel(cancelled)
        let nextItem = plan.items[1]
        let nextPlan = ExportPlan(items: [nextItem], settings: plan.settings)
        let nextURL = folder.appendingPathComponent("queued.jpg")
        queue.enqueue(nextPlan, destination: .file(nextURL))
        let nextJob = queue.jobs.last!
        for _ in 0..<500 {
            if !queue.running { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        assert(!queue.running && first.phase == .finished && first.failures.isEmpty)
        assert(cancelled.phase == .cancelled)
        assert(nextJob.phase == .finished && nextJob.failures.isEmpty)
        let nextWorker = RAWDeveloper(colorSpace: nextItem.recipe.colorSpace, rawSettings: nextItem.recipe.rawSettings)
        let nextExpected = try await nextWorker.exportHEIF(nextItem.source, mapping: nextItem.recipe.mapping, settings: nextPlan.settings)
        let nextWritten = try Data(contentsOf: nextURL)
        assert(pixels(nextWritten) == pixels(nextExpected))
        let written = try Data(contentsOf: destination)
        assert(written == bytes)
        assert(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("cancelled.jpg").path))
        print("PASS: frozen sidecars/Film Lock/format, saved and fresh execution, preparation failures, cached single export, queue cancellation")
    }
}
