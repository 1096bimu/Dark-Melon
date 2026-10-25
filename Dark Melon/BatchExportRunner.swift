#if os(macOS)
import Foundation
import ImageIO

nonisolated final class BatchMemoryPressure: @unchecked Sendable {
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
    static func run(plan: ExportPlan, destination: URL,
                    progress: @escaping @MainActor @Sendable (Result, Int) -> Void) async {
        let pressure = BatchMemoryPressure()
        let budget = BatchExportBudget.limit(memory: ProcessInfo.processInfo.physicalMemory)
        let items = plan.items
        let settings = plan.settings
        let costs = items.map { BatchExportBudget.bytes(pixels: $0.pixels, scale: settings.scale) }
        let allocation = BatchExportBudget.allocation(costs: costs,
            cpuCount: ProcessInfo.processInfo.activeProcessorCount, budget: budget)
        let cpuLimit = allocation.parallelism
        await withTaskGroup(of: Result.self) { group in
            var next = 0, active = 0
            var reserved: UInt64 = 0
            while next < items.count || active > 0 {
                while !Task.isCancelled, next < items.count,
                      BatchExportBudget.admits(cost: costs[next], reserved: reserved, active: active,
                                               cpuLimit: cpuLimit, budget: budget, pressured: pressure.isPressured) {
                    let item = items[next], source = item.source, cost = costs[next]
                    group.addTask {
                        do {
                            try Task.checkCancellation()
                            let recipe = item.recipe
                            let worker = RAWDeveloper(colorSpace: recipe.colorSpace, rawSettings: recipe.rawSettings,
                                                      rawWhiteBalance: recipe.mapping.rawWhiteBalance, lutConfiguration: item.lutConfiguration,
                                                      exporting: true, memoryLimitMB: allocation.megabytesPerFile)
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
