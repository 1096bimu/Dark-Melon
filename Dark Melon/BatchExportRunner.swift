#if os(macOS)
import Foundation
import ImageIO

nonisolated private final class BatchMemoryPressure: @unchecked Sendable {
    private let lock = NSLock()
    private var pressured = false
    private let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility))
    init() {
        source.setEventHandler { [weak self] in
            guard let self else { return }
            lock.lock()
            pressured = !source.data.contains(.normal)
            lock.unlock()
        }
        source.resume()
    }
    var isPressured: Bool {
        lock.lock(); defer { lock.unlock() }
        return pressured
    }
    deinit { source.cancel() }
}

nonisolated enum BatchExportRunner {
    struct Result: Sendable {
        let source: URL
        let cost: UInt64
        let error: String?
        let cancelled: Bool
    }

    @concurrent
    static func run(files: [URL], destination: URL, settings: HEIFSettings,
                    progress: @escaping @MainActor @Sendable (Result, Int) -> Void) async {
        let pressure = BatchMemoryPressure()
        let budget = BatchExportBudget.limit(memory: ProcessInfo.processInfo.physicalMemory)
        let cpuLimit = max(1, ProcessInfo.processInfo.activeProcessorCount)
        // Properties only: never decode the pixel data during admission planning.
        let costs = files.map { url in
            autoreleasepool {
                let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
                let properties = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
                let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
                let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
                return BatchExportBudget.bytes(pixels: width > 0 && height > 0 ? width * height : 100_000_000,
                                               scale: settings.scale)
            }
        }
        await withTaskGroup(of: Result.self) { group in
            var next = 0, active = 0
            var reserved: UInt64 = 0
            while next < files.count || active > 0 {
                while !Task.isCancelled, next < files.count,
                      BatchExportBudget.admits(cost: costs[next], reserved: reserved, active: active,
                                               cpuLimit: cpuLimit, budget: budget, pressured: pressure.isPressured) {
                    let source = files[next], cost = costs[next]
                    group.addTask {
                        do {
                            try Task.checkCancellation()
                            guard let recipe = try await RecipeStore.shared.load(for: source) else {
                                return Result(source: source, cost: cost, error: "Saved settings are missing.", cancelled: false)
                            }
                            let worker = RAWDeveloper(colorSpace: recipe.colorSpace)
                            try await worker.exportBatch(source, mapping: recipe.mapping, settings: settings, destination: destination)
                            return Result(source: source, cost: cost, error: nil, cancelled: false)
                        } catch is CancellationError {
                            return Result(source: source, cost: cost, error: nil, cancelled: true)
                        } catch {
                            return Result(source: source, cost: cost, error: error.localizedDescription, cancelled: false)
                        }
                    }
                    reserved += cost; active += 1; next += 1
                }
                if Task.isCancelled { group.cancelAll() }
                guard active > 0, let result = await group.next() else { break }
                reserved -= result.cost; active -= 1
                await progress(result, active)
            }
        }
    }
}
#endif
