import Foundation
@testable import Dark_Melon

@main struct ExportPlanRAWChecks {
    @MainActor static func main() async throws {
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: source)
        let plain = try await ExportPlan.prepare(files: [file], film: nil, maximizeRAWRange: false) { _, _ in }
        assert(plain.failures.isEmpty)
        let base = plain.items[0].recipe
        assert(base.rawSettings?.values[.exposure] == 0)
        assert(base.rawSettings?.values[.shadowBias] == 2)
        assert(base.rawSettings?.values[.luminance] == 0)
        assert(base.mapping.rawWhiteBalance != nil)
        let fitted = try await ExportPlan.prepare(files: [file], film: nil, maximizeRAWRange: true) { _, _ in }
        assert(fitted.failures.isEmpty)
        assert(fitted.items[0].recipe.rawSettings?.values[.shadowBias] == 0)
        let fittedExposure = fitted.items[0].recipe.rawSettings!.values[.exposure]!
        assert((-5...5).contains(fittedExposure))
        var saved = base
        saved.rawSettings?.values[.exposure] = 1
        saved.rawSettings?.values[.shadowBias] = 1.5
        try await RecipeStore.shared.save(saved, for: file)
        let restored = try await ExportPlan.prepare(files: [file], film: nil, maximizeRAWRange: true) { _, _ in }
        assert(restored.failures.isEmpty)
        assert(restored.items[0].recipe.rawSettings?.values[.exposure] == 1)
        assert(restored.items[0].recipe.rawSettings?.values[.shadowBias] == 1.5)
        assert(plain.items[0].recipe.rawSettings?.values[.exposure] == 0)
        print("PASS: RAW defaults/WB frozen, fresh range fitting, saved RAW settings preserved; fitted exposure \(fittedExposure)")
    }
}
