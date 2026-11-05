import SwiftUI
#if os(macOS)
import IOKit.ps
#else
import UIKit
#endif

/// Bounded background jobs; normal opening consumes the same source cache.
@Observable @MainActor
final class TurboMode {
    static let shared = TurboMode()
    @ObservationIgnored var browserCenter: URL?
    var enabled = false
    private var policy = "never"
    private var externalPower: Bool?

    func setEnabled(_ value: Bool) {
        enabled = value
        RAWImageCache.shared.setTurbo(value)
    }

    func refresh(policy newPolicy: String) {
        #if os(macOS)
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let plugged = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? == kIOPSACPowerValue
        #else
        UIDevice.current.isBatteryMonitoringEnabled = true
        let plugged = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        #endif
        guard externalPower == nil || policy != newPolicy || (newPolicy == "plugged" && externalPower != plugged) else { return }
        policy = newPolicy; externalPower = plugged
        setEnabled(newPolicy == "always" || (newPolicy == "plugged" && plugged))
    }

    struct Request: Equatable {
        var enabled: Bool
        var current: URL?
        var files: [URL]
        var rawFiles: Set<URL>
        var busy: Bool
        var film: FilmSettings?
        var canvas: CGSize
    }

    static func ordered(_ files: [URL], around current: URL?) -> [URL] {
        guard let current, let index = files.firstIndex(of: current) else { return files }
        return (1..<max(1, files.count)).flatMap { distance in
            [index + distance, index - distance].compactMap { files.indices.contains($0) ? files[$0] : nil }
        }
    }

    func preload(_ request: Request, overrides: [URL: DevelopmentRecipe]) async {
        guard request.enabled, !request.busy else { return }
        let currentIndex = request.current.flatMap { request.files.firstIndex(of: $0) }
        let neighbors = Self.ordered(request.files, around: request.current).filter { url in
            guard let currentIndex, let index = request.files.firstIndex(of: url) else { return false }
            return abs(index - currentIndex) <= 4 && request.rawFiles.contains(url)
        }
        let files = request.files.filter { request.rawFiles.contains($0) && $0 != request.current }
        let concurrency = max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
        await withTaskGroup(of: URL.self) { group in
            var assigned: Set<URL> = []
            var completed: Set<URL> = []
            var running = 0
            while assigned.count < files.count || running > 0 {
                guard !Task.isCancelled else { group.cancelAll(); return }
                // Stop admitting jobs during exports or memory pressure; already
                // running decodes finish and release their temporary resources.
                while running < concurrency, RAWImageCache.shared.canPrefetch, !Task.isCancelled {
                    let priority: [URL]
                    if !neighbors.allSatisfy({ completed.contains($0) }) {
                        priority = neighbors
                    } else {
                        let center = browserCenter.flatMap { request.files.contains($0) ? $0 : nil } ?? request.current
                        priority = (center.map { [$0] } ?? []) + Self.ordered(request.files, around: center)
                    }
                    guard let url = priority.first(where: { files.contains($0) && !assigned.contains($0) }) else { break }
                    assigned.insert(url)
                    running += 1
                    group.addTask(priority: .utility) {
                        do {
                            try Task.checkCancellation()
                            _ = try await BrowserFileDevelopment.load(url, override: overrides[url], bins: 256,
                                film: request.film, comparisonCanvas: request.canvas)
                        } catch { /* An unreadable neighbor must not interrupt editing. */ }
                        return url
                    }
                }
                if running > 0 {
                    if let url = await group.next() { completed.insert(url) }
                    running -= 1
                } else {
                    do { try await Task.sleep(for: .seconds(2)) }
                    catch { group.cancelAll(); return }
                }
            }
        }
    }
}
