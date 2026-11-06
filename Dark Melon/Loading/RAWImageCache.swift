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
        let composite: DoubleExposure?
        let sourceStamps: [FileStamp]
        let development: RAWDevelopment
        var display: CGImage? = nil
        var cost: UInt64
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
    private var cacheLimit: UInt64
    private let memory: UInt64
    private let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility))

    init(memory: UInt64 = ProcessInfo.processInfo.physicalMemory) {
        self.memory = memory
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

    func setTurbo(_ enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        cacheLimit = enabled ? memory / 2 : memory / 5
        trim()
    }

    var canPrefetch: Bool {
        lock.lock(); defer { lock.unlock() }
        return !pressured && reserved == 0 && entries.reduce(UInt64(0)) { $0 + $1.cost } + 64 * 1024 * 1024 < allowance
    }

    private var allowance: UInt64 { pressured ? 0 : min(cacheLimit, budget - min(budget, reserved)) }
    private func trim() {
        if allowance == 0 { ranges.removeAll() }
        var total = entries.reduce(UInt64(0)) { $0 + $1.cost }
        while total > allowance, !entries.isEmpty {
            total -= entries.removeFirst().cost
        }
    }

    func lookup(_ stamp: FileStamp, space: ProcessingColorSpace, settings: RAWSettings?, balance: RAWWhiteBalance?, dustSpots: [DustSpot] = [], chromaticAberration: ChromaticAberration = ChromaticAberration(), requireFull: Bool = false, composite: DoubleExposure? = nil) -> RAWDevelopment? {
        lock.lock(); defer { lock.unlock() }
        // A modified/replaced file invalidates every old decode of that path.
        entries.removeAll { $0.stamp.url == stamp.url && $0.stamp != stamp }
        let sourceStamps = composite?.urls(relativeTo: stamp.url).compactMap(FileStamp.init) ?? []
        guard let index = entries.firstIndex(where: {
            $0.stamp == stamp && $0.space == space && $0.composite == composite && $0.sourceStamps == sourceStamps && (!requireFull || $0.development.fullResolutionReady) && $0.development.dustSpots == dustSpots && $0.development.chromaticAberration == chromaticAberration
                && $0.settings == (settings?.resolved(using: $0.development.rawDefaults ?? RAWSettings()) ?? $0.development.rawDefaults ?? RAWSettings())
                && $0.balance == (balance ?? $0.development.whitePoint.map(RAWWhiteBalance.init))
        }) else { return nil }
        let entry = entries.remove(at: index)
        entries.append(entry)
        return entry.development
    }

    func insert(_ development: RAWDevelopment, stamp: FileStamp, space: ProcessingColorSpace,
                settings: RAWSettings?, balance: RAWWhiteBalance?, composite: DoubleExposure? = nil) {

        let defaults = development.rawDefaults ?? RAWSettings()
        var entry = Entry(stamp: stamp, space: space, settings: settings?.resolved(using: defaults) ?? defaults,
                          balance: balance ?? development.whitePoint.map(RAWWhiteBalance.init), composite: composite, sourceStamps: composite?.urls(relativeTo: stamp.url).compactMap(FileStamp.init) ?? [], development: development,
                          cost: (development.fullResolutionReady ? UInt64(development.width) * UInt64(development.height) * 8 : 0)
                            + UInt64(development.preview.bytesPerRow) * UInt64(development.preview.height))
        lock.lock(); defer { lock.unlock() }
        if let display = entries.last(where: { $0.development.id == development.id })?.display {
            entry.display = display
            entry.cost += UInt64(display.bytesPerRow * display.height)
        }
        guard entry.cost <= allowance else { return }
        // Keep one correction version per decode; do not retain a second uncorrected RGB copy.
        entries.removeAll { $0.development.id == development.id || ($0.stamp.url == stamp.url &&
            ($0.stamp != stamp || ($0.space == entry.space && $0.settings == entry.settings && $0.balance == entry.balance && $0.composite == entry.composite))) }
        entries.append(entry)
        trim()
    }

    /// Presentation-only, deliberately independent of recipe validation. The normal
    /// open path must still validate the file and produce the authoritative edit.
    func firstDisplay(for url: URL) -> CGImage? {
        let key = url.standardizedFileURL
        lock.lock(); defer { lock.unlock() }
        return entries.last(where: { $0.development.url.standardizedFileURL == key || $0.stamp.url == key })
            .map { $0.display ?? $0.development.preview }
    }

    func rememberDisplay(_ image: CGImage, sourceID: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard let index = entries.firstIndex(where: { $0.development.id == sourceID }) else { return }
        if let old = entries[index].display { entries[index].cost -= UInt64(old.bytesPerRow * old.height) }
        entries[index].display = image
        entries[index].cost += UInt64(image.bytesPerRow * image.height)
        trim()
    }

    #if DEBUG
    /// Inspect resident entries without touching LRU order or doing filesystem IO.
    /// Any retained recipe variant counts; this is not a promise of an exact recipe hit.
    func debugStatus(for url: URL) -> Bool? {
        let key = url.standardizedFileURL
        lock.lock(); defer { lock.unlock() }
        var status: Bool?
        for entry in entries where entry.development.url.standardizedFileURL == key || entry.stamp.url == key {
            status = (status ?? false) || entry.development.fullResolutionReady
        }
        return status
    }
    #endif

    func discardPixels(for url: URL) {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        lock.lock(); defer { lock.unlock() }
        entries.removeAll { $0.stamp.url == canonical }
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

    /// Leave room for export reservations and memory pressure during comparison.
    func comparisonParallelism(pixels: Double) -> Int {
        lock.lock(); defer { lock.unlock() }
        let available = budget - min(budget, reserved)
        let cost = BatchExportBudget.bytes(pixels: pixels, scale: 0.25)
        return pressured ? 1 : max(1, min(2, Int(available / max(1, cost))))
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
