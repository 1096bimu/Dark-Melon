import Foundation
import ImageIO

nonisolated struct PreparedExportItem: Sendable {
    let source: URL
    let recipe: DevelopmentRecipe
    let pixels: Double
    let lutConfiguration: LUTConfiguration?

    init(source: URL, recipe: DevelopmentRecipe, pixels: Double? = nil) {
        self.source = source
        self.recipe = recipe
        self.lutConfiguration = recipe.mapping.lutID.map { LUTStore.shared.configuration(for: $0) }
        self.pixels = pixels ?? Self.pixelCount(of: source)
    }

    static func pixelCount(of source: URL) -> Double {
        let container = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        let properties = container.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        return width > 0 && height > 0 ? width * height : 100_000_000
    }
}

/// Only values enter execution: no sidecar reads, live preferences or Film Lock.
nonisolated struct ExportPlan: Sendable {
    let items: [PreparedExportItem]
    let settings: HEIFSettings
    let failures: [String]

    init(items: [PreparedExportItem], settings: HEIFSettings, failures: [String] = []) {
        self.items = items
        self.settings = settings
        self.failures = failures
    }

    @concurrent
    static func prepare(files: [URL], film: FilmSettings?, maximizeRAWRange: Bool,
                        rawDefault: RAWDefaultPreset? = nil,
                        progress: @escaping @MainActor @Sendable (Int, Int) -> Void) async throws -> (items: [PreparedExportItem], failures: [String]) {
        let rawDefault = if let rawDefault { rawDefault } else { await EditLibrary.shared.rawDefaultPreset }
        let pixels = try files.map {
            try Task.checkCancellation()
            return PreparedExportItem.pixelCount(of: $0)
        }
        let costs = pixels.map { BatchExportBudget.bytes(pixels: $0, scale: 0) }
        let budget = BatchExportBudget.limit(memory: ProcessInfo.processInfo.physicalMemory)
        let cpuLimit = max(1, ProcessInfo.processInfo.activeProcessorCount)
        #if os(macOS)
        let pressure = BatchMemoryPressure()
        #endif
        let results = await withTaskGroup(of: PreparationResult.self) { group in
            var results: [PreparationResult] = []
            var next = 0, active = 0
            var reserved: UInt64 = 0
            while next < files.count || active > 0 {
                #if os(macOS)
                let pressured = pressure.isPressured
                #else
                let pressured = false
                #endif
                while !Task.isCancelled, next < files.count,
                      BatchExportBudget.admits(cost: costs[next], reserved: reserved, active: active,
                                               cpuLimit: cpuLimit, budget: budget, pressured: pressured) {
                    let index = next, url = files[index], cost = costs[index]
                    group.addTask {
                        do {
                            try Task.checkCancellation()
                            let target = try await BrowserRecipeTarget.load(url)
                            let worker = RAWDeveloper(colorSpace: target.recipe.colorSpace, rawSettings: target.recipe.rawSettings,
                                                      rawWhiteBalance: target.recipe.mapping.rawWhiteBalance)
                            let resolved = try await worker.resolveExportRecipe(url, recipe: target.recipe, isRAW: target.isRAW,
                                maximizeRange: target.savedRecipe == nil && maximizeRAWRange)
                            try Task.checkCancellation()
                            let defaults = target.isRAW && target.savedRecipe == nil
                                ? rawDefault?.applying(to: resolved) ?? resolved : resolved
                            let recipe = film?.applying(to: defaults) ?? defaults
                            return PreparationResult(index: index, cost: cost,
                                item: PreparedExportItem(source: url, recipe: recipe, pixels: pixels[index]), error: nil)
                        } catch is CancellationError {
                            return PreparationResult(index: index, cost: cost, item: nil, error: nil)
                        } catch {
                            return PreparationResult(index: index, cost: cost, item: nil,
                                error: "\(url.lastPathComponent): \(error.localizedDescription)")
                        }
                    }
                    reserved += cost; active += 1; next += 1
                }
                if Task.isCancelled { group.cancelAll() }
                guard active > 0, let result = await group.next() else { break }
                reserved -= result.cost; active -= 1
                results.append(result)
                await progress(results.count, files.count)
            }
            return results.sorted { $0.index < $1.index }
        }
        try Task.checkCancellation()
        return (results.compactMap(\.item), results.compactMap(\.error))
    }

    private struct PreparationResult: Sendable {
        let index: Int
        let cost: UInt64
        let item: PreparedExportItem?
        let error: String?
    }
}
