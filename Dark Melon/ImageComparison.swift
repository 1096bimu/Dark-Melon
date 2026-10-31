import SwiftUI
import CoreImage

nonisolated struct ComparisonInput: Identifiable, Equatable {
    var id: String
    var url: URL
    var title: String
    var recipe: DevelopmentRecipe?
}

enum ComparisonMode: String, CaseIterable {
    case independent = "No Sync", area = "Same Area", combine = "Combine"
}

@MainActor @Observable final class ImageComparisonSession {
    struct Pane: Identifiable {
        var id: String
        var title: String
        var development: RAWDevelopment?
        var overviewDevelopment: RAWDevelopment?
        var recipe: DevelopmentRecipe?
        var worker: RAWDeveloper?
        var images: PreviewImages?
        var detail: PreviewDetail?
        var error: String?
    }
    var panes: [Pane] = []
    var mode: ComparisonMode = .area
    var count = 0
    private var pressured = false
    private let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
    init() {
        pressure.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pressured = !self.pressure.data.contains(.normal)
                if self.pressured {
                    self.jobs.removeAll { $0.0.hasPrefix("detail:") }
                    self.detailRevisions.removeAll()
                    for i in self.panes.indices {
                        self.panes[i].detail = nil
                        self.panes[i].development = self.panes[i].overviewDevelopment
                    }
                    let sources = self.sources
                    Task { await sources.releaseDetails() }
                }
            }
        }
        pressure.resume()
    }
    isolated deinit {
        pressure.cancel()
        for task in running.values { task.cancel() }
        let sources = sources
        Task { await sources.cancel() }
    }
    private var sources = ComparisonSources()
    private var generation = UUID()
    private var jobs: [(String, @MainActor () async -> Void)] = []
    private var running: [UUID: Task<Void, Never>] = [:]
    private var detailRevisions: [String: UUID] = [:]
    private var overviewRemaining = 0
    private var deferredDetails: [String: (PreviewRegion, Bool)] = [:]

    func stop() {
        generation = UUID()
        let oldSources = sources
        sources = ComparisonSources()
        Task { await oldSources.cancel() }
        jobs.removeAll(); deferredDetails.removeAll(); detailRevisions.removeAll()
        for task in running.values { task.cancel() }
        // Keep cancelled work counted until it actually returns, including GPU waits.
        panes.removeAll()
    }
    private func enqueue(_ key: String, operation: @escaping @MainActor () async -> Void) {
        jobs.removeAll { $0.0 == key }
        jobs.append((key, operation)); drain()
    }
    private func drain() {
        let pixels = panes.compactMap { $0.development.map { Double($0.width) * Double($0.height) } }.max() ?? 0
        while running.count < RAWImageCache.shared.comparisonParallelism(pixels: pixels), !jobs.isEmpty {
            let (_, operation) = jobs.removeFirst(), id = UUID()
            running[id] = Task { [weak self] in
                await operation()
                self?.running[id] = nil
                self?.drain()
            }
        }
    }
    func start(_ inputs: [ComparisonInput], film: FilmSettings?, canvas: CGSize) {
        stop()
        count = inputs.count
        let visible = Array(inputs.prefix(4)), token = generation
        let sources = self.sources
        panes = visible.map { Pane(id: $0.id, title: $0.title) }
        overviewRemaining = visible.count
        for input in visible {
            enqueue("open:" + input.id) { [weak self] in
                guard let self, self.generation == token else { return }
                do {
                    let loaded = try await BrowserFileDevelopment.load(input.url, override: input.recipe,
                        bins: 256, film: film, comparisonCanvas: canvas, comparisonSources: sources)
                    try Task.checkCancellation()
                    let source = try await loaded.worker.overview(loaded.development, canvas: canvas)
                    let images = try await sources.render(development: loaded.development, worker: loaded.worker, source: source, mapping: loaded.recipe.mapping, canvas: canvas)
                    try Task.checkCancellation()
                    guard self.generation == token,
                          let i = self.panes.firstIndex(where: { $0.id == input.id }) else { return }
                    self.panes[i].development = loaded.development
                    var overview = RAWDevelopment(preview: source, linearSource: CIImage(cgImage: source), url: loaded.development.url,
                        width: loaded.development.width, height: loaded.development.height,
                        whitePoint: loaded.development.whitePoint, metadata: loaded.development.metadata,
                        isRAW: loaded.development.isRAW, rawDefaults: loaded.development.rawDefaults,
                        sourceHeadroom: loaded.development.sourceHeadroom, fullResolutionReady: false)
                    overview.id = loaded.development.id
                    self.panes[i].overviewDevelopment = overview
                    self.panes[i].recipe = loaded.recipe
                    self.panes[i].worker = loaded.worker
                    self.panes[i].images = images
                } catch {
                    guard self.generation == token else { return }
                    if !(error is CancellationError), let i = self.panes.firstIndex(where: { $0.id == input.id }) {
                        self.panes[i].error = error.localizedDescription
                    }
                }
                guard self.generation == token else { return }
                self.overviewRemaining -= 1
                if self.overviewRemaining == 0 {
                    let pending = self.deferredDetails; self.deferredDetails.removeAll()
                    for (id, value) in pending { self.requestDetail(id, region: value.0, hdr: value.1) }
                }
            }
        }
    }
    func requestDetail(_ id: String, region: PreviewRegion, hdr: Bool) {
        guard !pressured else { return }
        if overviewRemaining > 0 { deferredDetails[id] = (region, hdr); return }
        guard let pane = panes.first(where: { $0.id == id }), let development = pane.development,
              let recipe = pane.recipe, let worker = pane.worker, let images = pane.images else { return }
        let size = recipe.mapping.transform?.resolution(width: development.width, height: development.height, estimate: .maximum)
            ?? CGSize(width: development.width, height: development.height)
        let outputHDR = hdr && images.hasHDROutput
        if pane.detail?.covers(region, sourceID: development.id, mapping: recipe.mapping, hdr: outputHDR, outputSize: size) == true { return }
        let overviewScale = Double(images.source.width) / Double(development.width)
        if PreviewResolution.requiredScale(display: region.displayPixels, output: size) <= overviewScale * 1.01 { return }
        let token = generation, revision = UUID()
        let sources = self.sources
        detailRevisions[id] = revision
        enqueue("detail:" + id) { [weak self] in
            guard let self, self.generation == token, self.detailRevisions[id] == revision else { return }
            do {
                let full = development.fullResolutionReady ? development : try await sources.fullResolution(key: .init(url: development.url.standardizedFileURL, space: recipe.colorSpace, raw: recipe.rawSettings, balance: recipe.mapping.rawWhiteBalance), worker: worker, development: development)
                try Task.checkCancellation()
                guard self.generation == token, self.detailRevisions[id] == revision else { return }
                let detail = try await sources.detail(development: full, worker: worker, mapping: recipe.mapping, hdr: outputHDR, region: region)
                try Task.checkCancellation()
                guard self.generation == token, self.detailRevisions[id] == revision,
                      let i = self.panes.firstIndex(where: { $0.id == id }) else { return }
                self.panes[i].development = full
                self.panes[i].detail = detail
            } catch { /* Keep the overview when optional refinement fails. */ }
        }
    }
}

struct ImageComparisonView: View {
    var session: ImageComparisonSession
    var hdr: Bool
    @State private var controlsVisible = true
    @State private var hoveredAreas: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func hover(_ area: String, inside: Bool) {
        if inside { hoveredAreas.insert(area) } else { hoveredAreas.remove(area) }
    }

    var body: some View {
        Group {
            #if os(macOS)
            ComparisonCanvas(session: session, hdr: hdr)
            #else
            Color.black
            #endif
        }
        .overlay {
            GeometryReader { geometry in
                let rows = session.panes.count > 2 ? 2 : 1
                let width = geometry.size.width / 2
                let height = geometry.size.height / CGFloat(rows)
                ZStack(alignment: .topLeading) {
                    HStack {
                        Spacer(minLength: 8)
                        Picker("Comparison", selection: Binding(get: { session.mode }, set: { session.mode = $0 })) {
                            ForEach(ComparisonMode.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                        }.pickerStyle(.segmented).frame(maxWidth: 350)
                            .modifier(PreviewOverlayStyle())
                        Spacer(minLength: 8)
                    }
                    .opacity(controlsVisible ? 1 : 0)
                    .padding(.top, 12)
                    .frame(width: geometry.size.width, height: 60)
                    .contentShape(Rectangle())
                    .onHover { hover("modes", inside: $0) }

                    ForEach(Array(session.panes.enumerated()), id: \.element.id) { index, pane in
                        Text(pane.title)
                            .font(.caption).foregroundStyle(.white)
                            .lineLimit(1).truncationMode(.middle)
                            .modifier(PreviewOverlayStyle())
                            .padding(.horizontal, 12)
                            .opacity(controlsVisible ? 1 : 0)
                            .frame(width: width, height: 36)
                            .contentShape(Rectangle())
                            .onHover { hover(pane.id, inside: $0) }
                            .offset(x: CGFloat(index % 2) * width,
                                    y: index < 2 ? 60 : height + 12)
                    }
                    if session.count > 4 {
                        Text("Showing 4 of \(session.count)")
                            .font(.caption).foregroundStyle(.white)
                            .modifier(PreviewOverlayStyle())
                            .opacity(controlsVisible ? 1 : 0)
                            .offset(x: 12, y: 108)
                            .onHover { hover("count", inside: $0) }
                    }
                }
            }
        }
        .task(id: hoveredAreas.isEmpty) {
            if !hoveredAreas.isEmpty { controlsVisible = true; return }
            do {
                try await Task.sleep(for: .seconds(5))
                try Task.checkCancellation()
                controlsVisible = false
            } catch { }
        }
        .animation(.easeInOut(duration: reduceMotion ? 0 : 0.2), value: controlsVisible)
    }
}

#if os(macOS)
private struct ComparisonCanvas: NSViewRepresentable {
    var session: ImageComparisonSession
    var hdr: Bool
    @Environment(\.hdrScreenSaverActive) private var dimmed
    @AppStorage("previewMouseControls") private var mouse = false
    @AppStorage("previewReverseMouseScroll") private var reverse = false
    func makeNSView(context: Context) -> ComparisonDisplay { ComparisonDisplay() }
    func updateNSView(_ view: ComparisonDisplay, context: Context) {
        view.update(session: session, hdr: hdr, dimmed: dimmed, mouse: mouse, reverse: reverse)
    }
}

final class ComparisonDisplay: NSView {
    struct Tile {
        var id: String
        var clip: NSView
        var image: HDRImagePreview.ImageDisplay
        var status: NSTextField
    }
    private var tiles: [Tile] = []
    private var mode: ComparisonMode = .area
    private var lastActive: String?
    private var synchronizing = false
    private var sharedViewport: (CGFloat, CGPoint)?
    private var lastHDR: Bool?
    private var regions: [String: PreviewRegion] = [:]
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true; layer?.backgroundColor = NSColor.black.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(session: ImageComparisonSession, hdr: Bool, dimmed: Bool, mouse: Bool, reverse: Bool) {
        let ids = session.panes.map(\.id)
        if tiles.map(\.id) != ids {
            let previous = Dictionary(uniqueKeysWithValues: tiles.map { ($0.id, $0) })
            tiles.filter { !ids.contains($0.id) }.forEach { $0.clip.removeFromSuperview() }
            regions = regions.filter { ids.contains($0.key) }
            tiles = ids.map { id in
                if let existing = previous[id] { return existing }
                let clip = NSView(); clip.wantsLayer = true; clip.layer?.masksToBounds = true
                let image = HDRImagePreview.ImageDisplay(viewport: PreviewViewport())
                image.allowsWhiteBalance = false
                let status = NSTextField(labelWithString: String(localized: "Loading image…"))
                status.textColor = .secondaryLabelColor; status.alignment = .center
                clip.addSubview(image); clip.addSubview(status); addSubview(clip)
                image.viewportChanged = { [weak self] in self?.synchronize(from: id) }
                return Tile(id: id, clip: clip, image: image, status: status)
            }
        }
        let changed = mode != session.mode
        let reference = tiles.first(where: { $0.id == lastActive }) ?? tiles.first
        let priorViewport = reference?.image.normalizedViewport
        let hdrChanged = lastHDR != hdr; lastHDR = hdr
        mode = session.mode
        needsLayout = true; layoutSubtreeIfNeeded()
        for (pane, tile) in zip(session.panes, tiles) {
            tile.image.mouseControls = mouse; tile.image.reverseMouseScroll = reverse
            tile.image.regionChanged = { [weak self, weak session] region in
                if let region {
                    self?.regions[pane.id] = region
                    session?.requestDetail(pane.id, region: region, hdr: hdr)
                }
            }
            tile.status.isHidden = pane.images != nil
            tile.status.stringValue = pane.error ?? String(localized: "Loading image…")
            guard let images = pane.images, let development = pane.development, let recipe = pane.recipe else { continue }
            let useHDR = hdr && images.hasHDROutput
            let size = recipe.mapping.transform?.resolution(width: development.width, height: development.height, estimate: .maximum)
                ?? CGSize(width: development.width, height: development.height)
            tile.image.display(useHDR ? images.hdr : images.sdr, sdrImage: images.sdr,
                surface: useHDR ? images.surfaceHDR : images.surfaceSDR, sdrSurface: images.surfaceSDR,
                sourceSize: size, detail: pane.detail?.hdr == useHDR ? pane.detail : nil,
                hdr: useHDR, sourceID: development.id, screenSaverActive: dimmed)
            if !changed, mode != .independent, let sharedViewport { tile.image.setNormalizedViewport(sharedViewport) }
        }
        if changed, let priorViewport, let reference {
            reference.image.setNormalizedViewport(priorViewport)
            synchronize(from: reference.id)
        }
        if hdrChanged {
            for (id, region) in regions { session.requestDetail(id, region: region, hdr: hdr) }
        }
    }
    override func layout() {
        super.layout()
        let columns = 2, rows = tiles.count > 2 ? 2 : 1
        let width = bounds.width / CGFloat(columns), height = bounds.height / CGFloat(rows)
        for (i, tile) in tiles.enumerated() {
            let cell = CGRect(x: CGFloat(i % columns) * width, y: CGFloat(rows - 1 - i / columns) * height, width: width, height: height)
            tile.clip.frame = cell
            tile.image.frame = mode == .combine ? CGRect(x: -cell.minX, y: -cell.minY, width: bounds.width, height: bounds.height) : tile.clip.bounds
            tile.image.comparisonClip = mode == .combine ? cell : nil
            tile.status.frame = CGRect(x: 8, y: height / 2 - 20, width: max(0,width-16), height: 40)
        }
    }
    private func synchronize(from id: String) {
        guard !synchronizing, let source = tiles.first(where: { $0.id == id }) else { return }
        lastActive = id
        guard mode != .independent else { return }
        synchronizing = true
        let state = source.image.normalizedViewport
        sharedViewport = state
        for tile in tiles where tile.id != id { tile.image.setNormalizedViewport(state) }
        synchronizing = false
    }
}
#endif

/// Coalesce matching decodes within one session, including snapshots with different
/// downstream edits. A session owns at most four sources and releases them on exit.
actor ComparisonSources {
    struct Key: Equatable, Sendable {
        var url: URL
        var space: ProcessingColorSpace
        var raw: RAWSettings?
        var balance: RAWWhiteBalance?
    }
    private struct RenderKey: Equatable {
        var source: UUID
        var mapping: ToneMapping
        var canvas: CGSize
    }
    private struct DetailKey: Equatable {
        var source: UUID
        var mapping: ToneMapping
        var hdr: Bool
        var region: PreviewRegion
    }
    private var renders: [(RenderKey, Task<PreviewImages, Error>)] = []
    private var details: [(DetailKey, Task<PreviewDetail, Error>)] = []
    private var reservations: [RAWImageCache.Reservation] = []
    func render(development: RAWDevelopment, worker: RAWDeveloper, source: CGImage, mapping: ToneMapping, canvas: CGSize) async throws -> PreviewImages {
        let key = RenderKey(source: development.id, mapping: mapping, canvas: canvas)
        if let task = renders.first(where: { $0.0 == key })?.1 { return try await task.value }
        let task = Task { try await worker.previews(source, mapping: mapping) }
        renders.append((key, task))
        return try await task.value
    }
    func detail(development: RAWDevelopment, worker: RAWDeveloper, mapping: ToneMapping, hdr: Bool, region: PreviewRegion) async throws -> PreviewDetail {
        let key = DetailKey(source: development.id, mapping: mapping, hdr: hdr, region: region)
        if let task = details.first(where: { $0.0 == key })?.1 { return try await task.value }
        let task = Task { try await worker.detail(development, mapping: mapping, hdr: hdr, region: region) }
        if details.count >= 4 { details.removeFirst() }
        details.append((key, task))
        return try await task.value
    }
    private var previews: [(Key, Task<RAWDevelopment, Error>)] = []
    private var full: [(Key, Task<RAWDevelopment, Error>)] = []
    func preview(key: Key, worker: RAWDeveloper, canvas: CGSize) async throws -> RAWDevelopment {
        try Task.checkCancellation()
        if let task = previews.first(where: { $0.0 == key })?.1 { return try await task.value }
        let task = Task { try await worker.develop(key.url, previewCanvas: canvas, progressive: true) }
        previews.append((key, task))
        return try await task.value
    }
    func fullResolution(key: Key, worker: RAWDeveloper, development: RAWDevelopment) async throws -> RAWDevelopment {
        try Task.checkCancellation()
        if let task = full.first(where: { $0.0 == key })?.1 { return try await task.value }
        let task = Task { try await worker.prepareFullResolution(development) }
        full.append((key, task))
        let result = try await task.value
        reservations.append(RAWImageCache.shared.reserve(UInt64(max(1, result.width)) * UInt64(max(1, result.height)) * 8))
        return result
    }
    func releaseDetails() {
        for entry in full { entry.1.cancel() }
        for entry in details { entry.1.cancel() }
        full.removeAll(); previews.removeAll(); details.removeAll(); reservations.removeAll()
    }
    func cancel() {
        for entry in previews + full { entry.1.cancel() }
        for entry in renders { entry.1.cancel() }
        for entry in details { entry.1.cancel() }
        previews.removeAll(); full.removeAll(); renders.removeAll(); details.removeAll(); reservations.removeAll()
    }
}
