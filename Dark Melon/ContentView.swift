import SwiftUI
import CoreImage
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingPasteSettings = false
    @State private var resettingTone = false
    @State private var browserModel = ImageBrowserModel()
    #if os(macOS)
    @State private var showingBatchExport = false
    #endif
    @State private var pastedSettings: CopiedSettings?
    @State private var recipeSourceURL: URL?
    @State private var savedRecipe: DevelopmentRecipe?
    @State private var savingRecipe = false
    @State private var rawSettings = RAWSettings()
    @State private var panel = EditorPanel.tone
    @State private var comparingColor = false
    @State private var comparingEffects = false
    @State private var comparingHLS = false
    @State private var colorSpace = ProcessingColorSpace.sRGB
    @State private var sourceURL: URL?
    @State private var developer = RAWDeveloper()
    @State private var histogramWorker = RAWDeveloper()
    @State private var exportWorker = RAWDeveloper()
    @State private var histogramBins = 1
    @State private var histogram: HistogramData?
    @State private var pendingAutoContrast: AutoWhiteRequest?
    @State private var pendingAutoWhite: AutoWhiteRequest?
    @State private var histogramError: String?
    @State private var exportSettings = HEIFSettings.restored()
    @State private var showingExportOptions = false
    @State private var exporting = false
    @State private var exportDocument: HEIFDocument?
    @State private var showingSave = false
    @State private var exportContentType = UTType.heic
    @State private var exportName = "Developed.heic"
    @State private var development: RAWDevelopment?
    @State private var mapping = ToneMapping()
    @State private var pickingWhiteBalance = false
    @State private var hdrPreview = true
    @State private var previewImages: PreviewImages?
    @State private var previewRevision = UUID()
    @State private var filename = "Dark Melon"
    @State private var importing = false
    @State private var loading = false
    @State private var errorMessage: String?

    private var currentRecipe: DevelopmentRecipe {
        DevelopmentRecipe(colorSpace: colorSpace, mapping: mapping)
    }

    private var previewMapping: ToneMapping {
        var result = mapping
        if comparingColor { result.color = ColorAdjustments() }
        if comparingHLS {
            result.hls = Array(repeating: HLSAdjustment(), count: 6)
            result.blackAndWhite = BlackAndWhiteSettings()
            result.blackAndWhite.isEnabled = mapping.blackAndWhite.isEnabled
        }
        if comparingEffects { result.clarity = 0; result.hdf = 0; result.grain.strength = 0 }
        return result
    }

    var body: some View {
        NavigationStack {
            EditorColumns {
                ImageFileBrowser(selectedURL: sourceURL, open: { load($0, resetEdits: true) }, model: browserModel)
                    .frame(minWidth: 180, idealWidth: 220, maxWidth: 320)
                    .disabled(loading)
            VStack(spacing: 0) {
                ZStack {
                    Color.black
                    if let previewImages {
                        #if os(macOS)
                        HDRImagePreview(image: hdrPreview ? previewImages.hdr : previewImages.sdr,
                                        hdr: hdrPreview, sourceID: development?.id ?? previewRevision,
                                        pickingWhiteBalance: pickingWhiteBalance) { center, radius in
                            pickingWhiteBalance = false
                            guard let development else { return }
                            let sourceID = development.id
                            let worker = developer
                            Task {
                                do {
                                    let balance = try await worker.sampleWhiteBalance(development.preview, center: center, radius: radius)
                                    guard self.development?.id == sourceID, !loading else { return }
                                    mapping.whiteBalance = balance
                                } catch { errorMessage = error.localizedDescription }
                            }
                        }
                            .padding(16)
                        #else
                        Image(decorative: hdrPreview ? previewImages.hdr : previewImages.sdr, scale: 1)
                            .allowedDynamicRange(hdrPreview ? .high : .standard)
                            .resizable()
                            .scaledToFit()
                            .padding(16)
                        #endif
                    } else if !loading && development == nil {
                        ContentUnavailableView {
                            Label("Open an Image", systemImage: "camera")
                        } description: {
                            Text("Open RAW, SDR, or HDR images to develop in linear RGB.")
                        } actions: {
                            Button("Open Image…") { importing = true }
                        }
                    }
                    if loading || (development != nil && previewImages == nil) {
                        ProgressView("Loading image…")
                            .padding(20)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottomTrailing) {
                    HStack(spacing: 8) {
                        Button("Copy", systemImage: "doc.on.doc") {
                            do { try SettingsClipboard.copy(currentRecipe, reference: development?.whitePoint) }
                            catch { errorMessage = error.localizedDescription }
                        }
                        .keyboardShortcut("c", modifiers: .command)
                        .help("Copy all development settings")
                        Button("Paste", systemImage: "doc.on.clipboard") {
                            do {
                                pastedSettings = try SettingsClipboard.read()
                                showingPasteSettings = true
                            } catch { errorMessage = error.localizedDescription }
                        }
                        .keyboardShortcut("v", modifiers: .command)
                        .help("Choose which development settings to paste")
                    }
                    .buttonStyle(.bordered)
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .padding(12)
                    .disabled(development == nil || loading)
                }
                .overlay(alignment: .topTrailing) {
                    if let development {
                        CameraMetadataOverlay(metadata: development.metadata, whitePoint: development.whitePoint)
                    }
                }
            }
            .frame(minWidth: 320)
                ScrollView {
                    Group {
                        if panel == .raw {
                            RAWControls(settings: $rawSettings, isRAW: development?.isRAW == true, commit: {
                                if let sourceURL { load(sourceURL, resetEdits: false) }
                            }, reset: {
                                if let defaults = development?.rawDefaults, let sourceURL {
                                    rawSettings = defaults
                                    load(sourceURL, resetEdits: false)
                                }
                            })
                        } else if panel == .color {
                            ColorControls(settings: $mapping.color, comparing: $comparingColor, monochrome: mapping.blackAndWhite.isEnabled)
                        } else if panel == .hls {
                            HLSControls(adjustments: $mapping.hls, comparing: $comparingHLS, blackAndWhite: $mapping.blackAndWhite)
                        } else if panel == .effects {
                            EffectsControls(clarity: $mapping.clarity, radius: $mapping.clarityRadius, hdf: $mapping.hdf, hdfRadius: $mapping.hdfRadius, grain: $mapping.grain, comparing: $comparingEffects)
                        } else {
                            VStack(spacing: 0) {
                                LinearHistogram(development: development, histogram: histogram,
                                                histogramError: histogramError, binCount: $histogramBins,
                                                mapping: $mapping, sdrSource: previewImages?.sdr,
                                                revision: previewRevision, colorSpace: colorSpace,
                                                resettingTone: resettingTone, resetTone: resetTone)
                                Divider()
                                SlopeEditor(mapping: $mapping)
                                Divider()
                                VectorscopeView(source: development?.preview,
                                                temperatureSamples: previewImages?.temperatureSamples ?? [], revision: development?.id ?? previewRevision,
                                                colorSpace: colorSpace, whitePoint: development?.whitePoint, mapping: Binding(
                                            get: { previewMapping },
                                            set: { mapping.whiteBalance = $0.whiteBalance }), pickingWhiteBalance: $pickingWhiteBalance)
                            }
                        }
                    }
                    .disabled(loading || development == nil)
                }
                .frame(minWidth: 320, idealWidth: 360, maxWidth: 480)
            }
            .onChange(of: exportSettings) { _, settings in settings.remember() }
            .onChange(of: mapping.blackAndWhite.isEnabled) { _, _ in pickingWhiteBalance = false }
            .onChange(of: panel) { _, _ in
                pickingWhiteBalance = false
                comparingColor = false
                comparingEffects = false
                comparingHLS = false
            }
            .onChange(of: development?.id) { _, _ in
                pickingWhiteBalance = false
                comparingColor = false
                comparingEffects = false
                comparingHLS = false
            }
            .onChange(of: mapping.white) { _, _ in
                if !loading { hdrPreview = false }
            }
            .onChange(of: mapping.hdrConcentrationOffset) { _, _ in
                if !loading { hdrPreview = mapping.hdrEnabled }
            }
            .onChange(of: mapping.hdrMax) { _, _ in
                if !loading { hdrPreview = mapping.hdrEnabled }
            }
            .task(id: PreviewRequest(mapping: previewMapping,
                                     sourceID: development?.id, loading: loading, waitingForAutoWhite: pendingAutoWhite != nil)) {
                guard let development, !loading else { return }
                do {
                    let renderedMapping = previewMapping
                    let images = try await developer.previews(development.preview, mapping: renderedMapping, whitePoint: development.whitePoint)
                    try Task.checkCancellation()
                    previewImages = images
                    previewRevision = UUID()
                    if pendingAutoWhite == nil, let pending = pendingAutoContrast,
                       pending.sourceID == development.id {
                        pendingAutoContrast = nil
                        guard pending.mapping == mapping, renderedMapping == mapping else { return }
                        let worker = try GPUHistogram(colorSpace: colorSpace, encoded: true)
                        let result = try await worker.calculate(image: CIImage(cgImage: images.sdr), sourceID: previewRevision, bins: 256)
                        try Task.checkCancellation()
                        guard mapping == renderedMapping, self.development?.id == development.id else { return }
                        if let statistics = SDRStatistics(counts: result.sdrLuma),
                           let contrast = AutoContrast.suggestion(median: statistics.median, mapping: mapping, space: colorSpace) {
                            mapping.concentration = contrast
                        }
                    }
                } catch is CancellationError {
                    // A newer drag position supersedes this render.
                } catch { errorMessage = error.localizedDescription }
            }
            .task(id: HistogramRequest(sourceID: development?.id, loading: loading, previewReady: previewImages != nil, bins: histogramBins)) {
                histogramError = nil
                guard let development, !loading, previewImages != nil else {
                    histogram = nil
                    return
                }
                do {
                    try await Task.sleep(for: .milliseconds(180))
                    let result = try await histogramWorker.buildHistogram(development.url,
                        sourceID: development.id, bins: histogramBins)
                    try Task.checkCancellation()
                    histogram = result
                    if let pending = pendingAutoWhite, pending.sourceID == development.id,
                       (result.histogram.first?.count ?? 0) > 1 {
                        pendingAutoWhite = nil
                        // Do not overwrite edits made while the asynchronous histogram loaded.
                        if mapping == pending.mapping, let white = result.overlapWhitePoint {
                            mapping.white = min(1, max(mapping.black + ToneMapping.minimumRange, white))
                            pendingAutoContrast = AutoWhiteRequest(sourceID: development.id, mapping: mapping)
                        } else if mapping != pending.mapping {
                            pendingAutoContrast = nil
                        }
                    }
                } catch is CancellationError {
                } catch { histogramError = error.localizedDescription }
            }
            .navigationTitle(filename)
            .focusedSceneValue(\.editorPanel, $panel)
            #if os(macOS)
            .focusedSceneValue(\.batchExport, browserModel.directory == nil ? nil : { showingBatchExport = true })
            .sheet(isPresented: $showingBatchExport) {
                if let directory = browserModel.directory { BatchExportView(directory: directory) }
            }
            #endif
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 12) {
                        Button(exporting ? "Preparing Image…" : "Export…", systemImage: "square.and.arrow.up") {
                            showingExportOptions = true
                        }
                        .keyboardShortcut("e", modifiers: [.command, .shift])
                        .disabled(development == nil || loading || exporting)
                        Button(savingRecipe ? "Saving Edits…" : savedRecipe == currentRecipe ? "Edits Saved" : "Save Edits", systemImage: "square.and.arrow.down") {
                            saveRecipe()
                        }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(development == nil || loading || savingRecipe || savedRecipe == currentRecipe)
                        .help("Save development settings beside the original image in an XMP sidecar")
                        Picker("Color space", selection: Binding(get: { colorSpace }, set: { selected in
                            guard selected != colorSpace else { return }
                            colorSpace = selected
                            if let sourceURL { load(sourceURL, resetEdits: false) }
                        })) {
                            ForEach(ProcessingColorSpace.allCases) { space in
                                Text(space.rawValue).tag(space)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 260)
                        .disabled(loading || exporting)
                        Button(hdrPreview ? "Preview: HDR" : "Preview: SDR") { hdrPreview.toggle() }
                            .keyboardShortcut("h", modifiers: [])
                            .disabled(!mapping.hdrEnabled)
                            .help("Toggle HDR or SDR display of the developed image")
                            .accessibilityValue(hdrPreview ? "HDR" : "SDR")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Picker("Panel", selection: $panel) {
                        ForEach(EditorPanel.allCases) { panel in Text(panel.rawValue).tag(panel) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 350)
                }
            }
            .sheet(isPresented: $showingPasteSettings) {
                SettingsPasteOptions { selection in
                    guard let pastedSettings, development != nil, !loading else { return }
                    pendingAutoWhite = nil
                    pendingAutoContrast = nil
                    comparingColor = false
                    comparingHLS = false
                    comparingEffects = false
                    pickingWhiteBalance = false
                    mapping = pastedSettings.applying(selection, to: mapping, reference: development?.whitePoint, space: colorSpace)
                }
            }
            .sheet(isPresented: $showingExportOptions) {
                if let development {
                    HEIFExportOptions(settings: $exportSettings, width: development.width,
                                      height: development.height, hdrEnabled: mapping.hdrEnabled,
                                      sourceURL: development.url, mapping: mapping, colorSpace: colorSpace,
                                      rawSettings: rawSettings, save: prepareExport)
                }
            }
            .fileExporter(isPresented: $showingSave, document: exportDocument,
                          contentType: exportContentType, defaultFilename: exportName) { result in
                if case .failure(let error) = result { errorMessage = error.localizedDescription }
                exportDocument = nil
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
                switch result {
                case .success(let url):
                    load(url, resetEdits: true)
                case .failure(let error): errorMessage = error.localizedDescription
                }
            }
            .alert("Dark Melon", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
        .preferredColorScheme(.dark)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                do { try autosaveCurrentFile() }
                catch { errorMessage = "Could not automatically save edits: \(error.localizedDescription)" }
            }
        }
        #if os(macOS)
        .background(FileSaveLifecycle(save: autosaveCurrentFile).frame(width: 0, height: 0))
        #endif
        #if os(macOS)
        .frame(minWidth: 1000, minHeight: 600)
        #endif
    }
    private func load(_ url: URL, resetEdits: Bool) {
        if resetEdits {
            do { try autosaveCurrentFile() }
            catch {
                errorMessage = "Could not automatically save edits: \(error.localizedDescription)"
                return
            }
        }
        sourceURL = url
        pendingAutoWhite = nil
        pendingAutoContrast = nil
        loading = true
        if resetEdits { mapping = ToneMapping(); savedRecipe = nil; recipeSourceURL = nil }
        development = nil
        previewImages = nil
        histogram = nil
        previewRevision = UUID()
        Task {
            defer { loading = false }
            do {
                var restored: DevelopmentRecipe?
                if resetEdits {
                    do { restored = try await RecipeStore.shared.load(for: url) }
                    catch { errorMessage = "Could not restore saved edits: \(error.localizedDescription)" }
                    if let restored {
                        colorSpace = restored.colorSpace
                        mapping = restored.mapping
                        savedRecipe = restored
                    } else {
                        colorSpace = try await developer.suggestedColorSpace(for: url)
                    }
                }
                let initializeEdits = resetEdits && restored == nil
                let options: RAWSettings? = resetEdits ? nil : rawSettings
                developer = RAWDeveloper(colorSpace: colorSpace, rawSettings: options)
                histogramWorker = RAWDeveloper(colorSpace: colorSpace, rawSettings: options)
                exportWorker = RAWDeveloper(colorSpace: colorSpace, rawSettings: options)
                let loaded = try await developer.develop(url)
                if resetEdits { rawSettings = loaded.rawDefaults ?? RAWSettings() }
                if resetEdits {
                    if initializeEdits, loaded.isRAW, let ev = loaded.metadata.ev100 { mapping.hdrMax = CameraMetadata.hdrGain(forEV: ev) }
                    hdrPreview = mapping.hdrEnabled
                }
                recipeSourceURL = url
                development = loaded
                if initializeEdits, loaded.isRAW { pendingAutoContrast = AutoWhiteRequest(sourceID: loaded.id, mapping: mapping) }
                if initializeEdits, loaded.isRAW {
                    pendingAutoWhite = AutoWhiteRequest(sourceID: loaded.id, mapping: mapping)
                }
                filename = url.lastPathComponent
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func resetTone() {
        guard let development, !loading, !resettingTone else { return }
        pendingAutoWhite = nil
        pendingAutoContrast = nil
        let original = mapping
        let space = colorSpace
        let worker = developer
        let histogramWorker = histogramWorker
        let existingHistogram = histogram
        let bins = histogramBins
        resettingTone = true
        Task {
            defer { resettingTone = false }
            do {
                // Analyze a fresh recipe so preserved color/effect edits cannot bias the default.
                var automatic = ToneMapping()
                if development.isRAW {
                    if let ev = development.metadata.ev100 {
                        automatic.hdrMax = CameraMetadata.hdrGain(forEV: ev)
                    }
                    let sourceHistogram: HistogramData
                    if let existingHistogram { sourceHistogram = existingHistogram }
                    else {
                        sourceHistogram = try await histogramWorker.buildHistogram(development.url,
                            sourceID: development.id, bins: bins)
                    }
                    if let white = sourceHistogram.overlapWhitePoint {
                        automatic.white = min(1, max(automatic.black + ToneMapping.minimumRange, white))
                    }
                    let images = try await worker.previews(development.preview, mapping: automatic,
                                                         whitePoint: development.whitePoint)
                    let histogramGPU = try GPUHistogram(colorSpace: space, encoded: true)
                    let result = try await histogramGPU.calculate(image: CIImage(cgImage: images.sdr),
                                                                 sourceID: UUID(), bins: 256)
                    if let statistics = SDRStatistics(counts: result.sdrLuma),
                       let contrast = AutoContrast.suggestion(median: statistics.median, mapping: automatic, space: space) {
                        automatic.concentration = contrast
                    }
                }
                guard self.development?.id == development.id, mapping == original else { return }
                mapping = SettingsPasteSelection(tone: true, whiteBalance: false, color: false,
                                                 hls: false, effects: false).applying(automatic, to: mapping)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func autosaveCurrentFile() throws {
        guard let sourceURL = recipeSourceURL,
              savedRecipe != currentRecipe,
              savedRecipe != nil || FileManager.default.fileExists(atPath: RecipeStore.sidecarURL(for: sourceURL).path) else { return }
        let recipe = currentRecipe
        try RecipeStore.shared.saveSynchronously(recipe, for: sourceURL)
        savedRecipe = recipe
    }

    private func saveRecipe() {
        guard let sourceURL, development != nil, !loading else { return }
        let recipe = currentRecipe
        savingRecipe = true
        defer { savingRecipe = false }
        do {
            try RecipeStore.shared.saveSynchronously(recipe, for: sourceURL)
            savedRecipe = recipe
        } catch { errorMessage = "Could not save edits: \(error.localizedDescription) If folder access is denied, open the containing folder in the file browser and try again." }
    }

    private func prepareExport() {
        guard let development else { return }
        let settings = exportSettings
        let snapshot = mapping
        exporting = true
        exportContentType = settings.format.type
        exportName = development.url.deletingPathExtension().lastPathComponent + "." + settings.format.fileExtension
        Task {
            defer { exporting = false }
            do {
                let data = try await exportWorker.exportHEIF(development.url, mapping: snapshot, settings: settings)
                exportDocument = HEIFDocument(data: data)
                showingSave = true
            } catch { errorMessage = error.localizedDescription }
        }
    }

}

private struct LinearHistogram: View {
    let development: RAWDevelopment?
    let histogram: HistogramData?
    let histogramError: String?
    @Binding var binCount: Int
    @Binding var mapping: ToneMapping
    let sdrSource: CGImage?
    let revision: UUID
    let colorSpace: ProcessingColorSpace
    let resettingTone: Bool
    let resetTone: () -> Void
    @State private var showingSDR = false
    @State private var sdrHistogram: HistogramData?
    @State private var sdrError: String?
    @State private var sdrWorker: GPUHistogram?
    @State private var workerSpace: ProcessingColorSpace?
    private var displayedHistogram: HistogramData? { showingSDR ? sdrHistogram : histogram }
    private let colors: [Color] = [.red, .green, .blue]

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button(showingSDR ? "SDR RGB" : "Linear RGB") { showingSDR.toggle() }
                    .fontWeight(.medium)
                    .help("Toggle the linear source histogram and the developed SDR preview histogram. Black and white points can only be adjusted in Linear RGB.")
                Spacer()
                Button("Reset Tone", action: resetTone)
                    .disabled(resettingTone)
            }
            HStack {
                if !showingSDR {
                    Text("Curve: SDR").foregroundStyle(.mint)
                    Text("HDR").foregroundStyle(.orange)
                }
                Spacer()
                if let development {
                    Text("\(development.width) × \(development.height)")
                        .foregroundStyle(.secondary)
                }
            }
            Canvas { context, size in
                for tick in 0...4 {
                    let x = size.width * CGFloat(tick) / 4
                    var grid = Path()
                    grid.move(to: CGPoint(x: x, y: 0))
                    grid.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(grid, with: .color(.white.opacity(0.12)), lineWidth: 1)
                }
                guard let histogram = displayedHistogram else { return }
                let channels = histogram.histogram
                let count = channels[0].count
                let scalingCounts = showingSDR
                    ? channels.flatMap { Array($0[3...252]) }
                    : channels.flatMap { $0 }
                let peak = max(1, scalingCounts.max() ?? 1)
                let logPeak = log1p(Double(peak))
                context.blendMode = .plusLighter
                for channel in 0..<3 {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: size.height))
                    for index in 0..<count {
                        let x0 = CGFloat(index) / CGFloat(count) * size.width
                        let x1 = CGFloat(index + 1) / CGFloat(count) * size.width
                        let value = Double(channels[channel][index])
                        let height = showingSDR ? min(1, value / Double(peak)) : log1p(value) / logPeak
                        let y = size.height * (1 - CGFloat(height))
                        path.addLine(to: CGPoint(x: x0, y: y))
                        path.addLine(to: CGPoint(x: x1, y: y))
                    }
                    path.addLine(to: CGPoint(x: size.width, y: size.height))
                    path.closeSubpath()
                    context.fill(path, with: .color(colors[channel].opacity(0.45)))
                    context.stroke(path, with: .color(colors[channel].opacity(0.85)), lineWidth: 0.75)
                }
            }
            .overlay {
                if !showingSDR { HistogramToneCurve(mapping: mapping).allowsHitTesting(false) }
            }
            .overlay {
                if !showingSDR { HistogramPoints(mapping: $mapping) }
            }
            .frame(height: 190)
            .onGeometryChange(for: Int.self) { geometry in
                max(1, Int(geometry.size.width.rounded(.down)))
            } action: { binCount = $0 }
            HStack {
                ForEach(0...4, id: \.self) { tick in
                    if showingSDR { Text("\(Int((Double(tick) * 255 / 4).rounded()))") }
                    else { Text(Double(tick) / 4, format: .number.precision(.fractionLength(2))) }
                    if tick < 4 { Spacer() }
                }
            }
            .foregroundStyle(.secondary)
            if let statistics = SDRStatistics(counts: sdrHistogram?.sdrLuma) {
                HStack {
                    Text("SDR P90–P10: \(statistics.spread)")
                    Spacer()
                    Text("Median: \(statistics.median)")
                }
                .foregroundStyle(.secondary)
                .help("SDR luma on a 0–255 scale, excluding bins below 3 and above 252. Each remaining pixel counts once.")
            } else {
                Text("SDR P90–P10: —   Median: —").foregroundStyle(.secondary)
            }
            if let error = showingSDR ? sdrError : histogramError {
                Text("Histogram unavailable: \(error)").foregroundStyle(.secondary)
            } else if displayedHistogram == nil, development != nil {
                ProgressView().controlSize(.small)
            }
        }
        .font(.caption.monospacedDigit())
        .padding(12)
        .background(.bar)
        .task(id: SDRHistogramRequest(revision: revision, bins: 256, space: colorSpace)) {
            guard let sdrSource else { sdrHistogram = nil; return }
            do {
                if sdrWorker == nil || workerSpace != colorSpace {
                    sdrWorker = try GPUHistogram(colorSpace: colorSpace, encoded: true)
                    workerSpace = colorSpace
                }
                let result = try await sdrWorker!.calculate(image: CIImage(cgImage: sdrSource),
                                                           sourceID: revision, bins: 256)
                try Task.checkCancellation()
                sdrHistogram = result
                sdrError = nil
            } catch is CancellationError {
            } catch { sdrError = error.localizedDescription }
        }
    }
}

private struct PreviewRequest: Equatable {
    let mapping: ToneMapping
    let sourceID: UUID?
    let loading: Bool
    let waitingForAutoWhite: Bool
}



private struct HistogramRequest: Equatable {
    let sourceID: UUID?
    let loading: Bool
    let previewReady: Bool
    let bins: Int
}

private struct AutoWhiteRequest {
    let sourceID: UUID
    let mapping: ToneMapping
}

private struct SDRHistogramRequest: Equatable {
    let revision: UUID
    let bins: Int
    let space: ProcessingColorSpace
}

