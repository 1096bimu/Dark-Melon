import Foundation
@testable import Dark_Melon

@main struct BrowserPendingChecks {
    @MainActor static func main() {
        let base = URL(fileURLWithPath: "/tmp/dark-melon-browser-check", isDirectory: true)
        let urls = (0..<500).map { base.appendingPathComponent("photo-\($0).jpg").standardizedFileURL }
        let baseline = DevelopmentRecipe(colorSpace: .sRGB, mapping: ToneMapping())
        var changed = baseline
        changed.mapping.concentration += 0.1
        var edits = PendingEdits()
        for url in urls.prefix(20) { edits.remember(url: url, recipe: changed, baseline: baseline, saved: nil) }
        let lookup = Set(edits.entries.map(\.url))
        precondition(urls.filter { lookup.contains($0) }.count == 20)
        precondition(edits.entry(for: urls[0])?.recipe == changed)
        edits.remove(urls[0]); precondition(edits.entry(for: urls[0]) == nil)
        let model = ImageBrowserModel()
        model.entries = urls.enumerated().map { BrowserEntry(url: $0.element, isFolder: false, hasSavedSettings: $0.offset == 499) }
        model.pendingURLs = lookup
        model.filter = .edited
        precondition(model.visibleFiles.count == 21)
        precondition(model.adjacentFile(to: urls[19], direction: 1) == urls[499])
        let start = ContinuousClock.now
        var count = 0
        for _ in 0..<100 { count += urls.filter { lookup.contains($0) }.count }
        precondition(count == 2000)
        print("PASS: pending lookup, removal, Edited filter/navigation; 50,000 in-memory lookups: \(start.duration(to: .now))")
    }
}
