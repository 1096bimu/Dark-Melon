import Foundation
import CoreGraphics

/// Disposable decoded pixels only. Recipes and pending edits live independently.
nonisolated final class RAWImageCache: @unchecked Sendable {
    static let shared = RAWImageCache()

    struct FileStamp: Equatable, Sendable {
        let url: URL
        let modified: Date
        let size: Int

        init?(_ url: URL) {
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            guard let values = try? canonical.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let modified = values.contentModificationDate, let size = values.fileSize else { return nil }
            self.url = canonical; self.modified = modified; self.size = size
        }
    }

    private struct Entry {
        let stamp: FileStamp
        let space: ProcessingColorSpace
        let settings: RAWSettings
        let balance: RAWWhiteBalance?
        let development: RAWDevelopment
        let cost: UInt64
    }

    private struct RangeEntry {
        let stamp: FileStamp
        let space: ProcessingColorSpace
        let settings: RAWSettings?
        let balance: RAWWhiteBalance?
        let result: RAWSettings
    }
    private var ranges: [RangeEntry] = []

    private let lock = NSLock()
    private var entries: [Entry] = [] // Oldest first; normally only a few full-size images.
    private var reserved: UInt64 = 0
    private var pressured = false
    private let budget: UInt64
    private let cacheLimit: UInt64
    private let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility))

    init(memory: UInt64 = ProcessInfo.processInfo.physicalMemory) {
        budget = BatchExportBudget.limit(memory: memory)
        cacheLimit = memory / 5
        pressure.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            self.pressured = !self.pressure.data.contains(.normal)
            self.trim()
        }
        pressure.resume()
    }
    deinit { pressure.cancel() }

    private var allowance: UInt64 { pressured ? 0 : min(cacheLimit, budget - min(budget, reserved)) }
    private func trim() {
        if allowance == 0 { ranges.removeAll() }
        var total = entries.reduce(UInt64(0)) { $0 + $1.cost }
        while total > allowance, !entries.isEmpty {
            total -= entries.removeFirst().cost
        }
    }

    func lookup(_ stamp: FileStamp, space: ProcessingColorSpace, settings: RAWSettings?, balance: RAWWhiteBalance?) -> RAWDevelopment? {
        lock.lock(); defer { lock.unlock() }
        // A modified/replaced file invalidates every old decode of that path.
        entries.removeAll { $0.stamp.url == stamp.url && $0.stamp != stamp }
        guard let index = entries.firstIndex(where: {
            $0.stamp == stamp && $0.space == space
                && $0.settings == (settings?.resolved(using: $0.development.rawDefaults ?? RAWSettings()) ?? $0.development.rawDefaults ?? RAWSettings())
                && $0.balance == (balance ?? $0.development.whitePoint.map(RAWWhiteBalance.init))
        }) else { return nil }
        let entry = entries.remove(at: index)
        entries.append(entry)
        return entry.development
    }

    func insert(_ development: RAWDevelopment, stamp: FileStamp, space: ProcessingColorSpace,
                settings: RAWSettings?, balance: RAWWhiteBalance?) {
        guard development.isRAW, development.fullResolutionReady else { return }
        let defaults = development.rawDefaults ?? RAWSettings()
        let entry = Entry(stamp: stamp, space: space, settings: settings?.resolved(using: defaults) ?? defaults,
                          balance: balance ?? development.whitePoint.map(RAWWhiteBalance.init), development: development,
                          cost: UInt64(development.width) * UInt64(development.height) * 8
                            + UInt64(development.preview.bytesPerRow) * UInt64(development.preview.height))
        lock.lock(); defer { lock.unlock() }
        guard entry.cost <= allowance else { return }
        entries.removeAll { $0.development.id == development.id || ($0.stamp.url == stamp.url && $0.stamp != stamp) }
        entries.append(entry)
        trim()
    }

    // Reopening an unedited photo must not repeat the optional Max Range probe.
    func range(_ stamp: FileStamp, space: ProcessingColorSpace, settings: RAWSettings?, balance: RAWWhiteBalance?) -> RAWSettings? {
        lock.lock(); defer { lock.unlock() }
        ranges.removeAll { $0.stamp.url == stamp.url && $0.stamp != stamp }
        guard let index = ranges.firstIndex(where: {
            $0.stamp == stamp && $0.space == space && $0.settings == settings && $0.balance == balance
        }) else { return nil }
        let entry = ranges.remove(at: index)
        ranges.append(entry)
        return entry.result
    }

    func rememberRange(_ result: RAWSettings, stamp: FileStamp, space: ProcessingColorSpace,
                       settings: RAWSettings?, balance: RAWWhiteBalance?) {
        lock.lock(); defer { lock.unlock() }
        guard allowance > 0 else { return }
        ranges.removeAll { $0.stamp == stamp && $0.space == space && $0.settings == settings && $0.balance == balance }
        ranges.append(RangeEntry(stamp: stamp, space: space, settings: settings, balance: balance, result: result))
        if ranges.count > 32 { ranges.removeFirst(ranges.count - 32) }
    }

    /// Exports have priority over retained browsing images within the same budget.
    func reserve(_ bytes: UInt64) -> Reservation {
        lock.lock()
        reserved += bytes
        trim()
        lock.unlock()
        return Reservation(cache: self, bytes: bytes)
    }

    final class Reservation: @unchecked Sendable {
        private let cache: RAWImageCache
        private let bytes: UInt64
        fileprivate init(cache: RAWImageCache, bytes: UInt64) { self.cache = cache; self.bytes = bytes }
        deinit {
            cache.lock.lock(); defer { cache.lock.unlock() }
            cache.reserved -= bytes
        }
    }
}
