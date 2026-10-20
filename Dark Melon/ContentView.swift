import SwiftUI
import CoreImage
import UniformTypeIdentifiers

struct ContentView: View {
    #if os(macOS)
    @State private var previewViewport = PreviewViewport()
    #endif
    @State private var pendingEdits = PendingEdits()
    @State private var pendingControlsWidth: CGFloat = 120
    @State private var baselineRecipe: DevelopmentRecipe?
    @State private var pendingTransition: (() -> Void)?
    @State private var confirmingDiscard = false
    @State private var showingPasteSettings = false
    @State private var browserPaste: BrowserFileDevelopment?
    @State private var browserExport: BrowserFileDevelopment?
    @State private var fileActionBusy = false
    @State private var deleteEditURL: URL?
    @State private var exportedSourceURL: URL?
    @State private var resettingTone = false
    @State private var browserModel = ImageBrowserModel()
    @State private var showingFileBrowser = true
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
    @AppStorage("guidedTutorialPresented") private var tutorialPresented = false
    @State private var tutorial = EditingTutorial()
    @State private var pendingPicker: EditorPickerTool?
    @AppStorage("autoTones") private var autoTones = false
    @State private var hoveredPreviewPixel: CGPoint?
    @State private var displayMode = PreviewHistogramMode.hdrLinear
    private var hdrPreview: Bool {
        get { displayMode.hdr }
        nonmutating set { displayMode.hdr = newValue }
    }
    @State private var previewImages: PreviewImages?
    @State private var adjustingTone = false
    @State private var toneLocatorImage: CGImage?
    @State private var previewRevision = UUID()
    @State private var filename = "Dark Melon"
    @State private var importing = false
    @State private var loading = false
    @State private var errorMessage: String?

    private var tutorialNeedsSave: Bool {
        tutorial.active && tutorial.step == .save && !tutorial.fulfilled
    }

    private var currentRecipe: DevelopmentRecipe {
        DevelopmentRecipe(colorSpace: colorSpace, mapping: mapping, rawSettings: mapping.rawWhiteBalance == nil ? nil : rawSettings)
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
                if showingFileBrowser {
                    ImageFileBrowser(selectedURL: sourceURL, open: { load($0, resetEdits: true) }, model: browserModel, changeDirectory: changeDirectory,
                                     fileAction: performFileAction, hasPendingEdit: hasPendingEdit)
                        .frame(minWidth: 180, idealWidth: 220, maxWidth: 320)
                        .disabled(loading || fileActionBusy)
                        .overlay { if fileActionBusy { ProgressView("Preparing…").padding().background(.regularMaterial) } }
                }
            VStack(spacing: 0) {
                ZStack {
                    Color.black
                    if let previewImages {
                        #if os(macOS)
                        HDRImagePreview(image: (adjustingTone ? toneLocatorImage : nil) ?? (hdrPreview ? previewImages.hdr : previewImages.sdr),
                                        hdr: hdrPreview, sourceID: development?.id ?? previewRevision,
                                        viewport: previewViewport,
                                        sampleTool: pickingWhiteBalance ? .whiteBalance : nil,
                                        hover: { hoveredPreviewPixel = $0 }) { center, radius in
                            let sampledMapping = mapping
                            pickingWhiteBalance = false
                            guard let development else { return }
                            let sourceID = development.id
                            let worker = developer
                            Task {
                                do {
                                    let balance = try await worker.sampleWhiteBalance(development.preview, center: center, radius: radius)
                                    guard self.development?.id == sourceID, !loading, mapping == sampledMapping else { return }
                                    mapping.whiteBalance = balance
                                } catch { errorMessage = error.localizedDescription }
                            }
                        }
                            .padding(16)
                        #else
                        Image(decorative: (adjustingTone ? toneLocatorImage : nil) ?? (hdrPreview ? previewImages.hdr : previewImages.sdr), scale: 1)
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
                .overlay(alignment: .bottomLeading) {
                    if !pendingEdits.entries.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Unsaved edits (\(pendingEdits.entries.count))").font(.caption.bold())
                                .lineLimit(1).frame(width: pendingControlsWidth, alignment: .leading)
                            ScrollView {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(pendingEdits.entries) { entry in
                                        Button(entry.url.lastPathComponent) { load(entry.url, resetEdits: true) }
                                            .buttonStyle(.plain)
                                            .foregroundStyle(entry.url == sourceURL?.standardizedFileURL ? Color.accentColor : .primary)
                                            .lineLimit(1).help(entry.url.path)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(width: pendingControlsWidth).frame(maxHeight: 110)
                            HStack {
                                Button("Save") { do { try savePendingEdits() } catch { errorMessage = error.localizedDescription } }
                                Button("Ignore") {
                                    requestDiscard {
                                        if let sourceURL { load(sourceURL, resetEdits: true) }
                                    }
                                }
                            }.buttonStyle(.bordered)
                                .fixedSize()
                                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pendingControlsWidth = $0 }
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(10)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                        .padding(.leading, 12).padding(.bottom, 64)
                        .disabled(loading)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    HStack(spacing: 8) {
                        Button("Copy", systemImage: "doc.on.doc") {
                            do { if let sourceURL { try SettingsClipboard.copy(currentRecipe, reference: development?.whitePoint, source: sourceURL) } }
                            catch { errorMessage = error.localizedDescription }
                        }
                        .keyboardShortcut("c", modifiers: .command)
                        .help("Copy all development settings")
                        Button("Paste", systemImage: "doc.on.clipboard") {
                            do {
                                pastedSettings = try SettingsClipboard.read()
                                browserPaste = nil
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
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if tutorial.active {
                    EditingTutorialGuide(tutorial: tutorial, imageReady: development != nil && !loading,
                                         hdrEnabled: mapping.hdrEnabled, advance: advanceTutorial,
                                         close: { tutorial.active = false })
                }
            }
            .frame(minWidth: 320)
                ScrollView {
                    VStack(spacing: 0) {
                        if panel == .tone || panel == .raw {
                            histogramView
                            Divider()
                        }
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
                            tonePanel
                        }
                    }
                    .disabled(loading || development == nil)
                }
                .frame(minWidth: 320, idealWidth: 360, maxWidth: 480)
            }
            .task {
                if !tutorialPresented {
                    tutorialPresented = true
                    startTutorial()
                }
            }
            .onChange(of: recipeSourceURL) { _, _ in
                if tutorial.active { tutorial.resetForImage() }
            }
            .onChange(of: autoTones) { _, enabled in
                if enabled { applyAutoTones() }
            }
            .onChange(of: exportSettings) { _, settings in settings.remember() }
            .onChange(of: mapping.blackAndWhite.isEnabled) { _, _ in
                pickingWhiteBalance = false
            }
            .onChange(of: panel) { _, _ in
                pickingWhiteBalance = false
                adjustingTone = false
                toneLocatorImage = nil
                comparingColor = false
                comparingEffects = false
                comparingHLS = false
                let requested = pendingPicker
                pendingPicker = nil
                if panel == .tone, let requested { togglePicker(requested) }
            }
            .onChange(of: development?.id) { _, _ in
                pendingPicker = nil
                pickingWhiteBalance = false
                adjustingTone = false
                toneLocatorImage = nil
                comparingColor = false
                comparingEffects = false
                comparingHLS = false
            }
            .onChange(of: mapping.white) { _, _ in
                if !loading { hdrPreview = false }
            }
            .task(id: ToneLocatorRequest(active: adjustingTone, mapping: previewMapping,
                                         revision: previewRevision, hdr: hdrPreview)) {
                guard adjustingTone, let development, let previewImages else { return }
                do {
                    let image = try await developer.toneLocator(development.preview,
                        preview: hdrPreview ? previewImages.hdr : previewImages.sdr,
                        mapping: previewMapping, hdr: hdrPreview)
                    try Task.checkCancellation()
                    toneLocatorImage = image
                } catch is CancellationError {
                } catch { errorMessage = error.localizedDescription }
            }
            .task(id: PreviewRequest(mapping: previewMapping,
                                     sourceID: development?.id, loading: loading, waitingForAutoWhite: pendingAutoWhite != nil)) {
                guard let development, !loading else { return }
                do {
                    let renderedMapping = previewMapping
                    let images = try await developer.previews(development.preview, mapping: renderedMapping)
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
                            mapping.setAutomaticHDRTarget()
                            baselineRecipe = currentRecipe
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
                            mapping.setAutomaticHDRTarget()
                            baselineRecipe = currentRecipe
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
            .focusedSceneValue(\.startTutorial, { startTutorial() })
            .focusedSceneValue(\.toggleEditorPicker, pickerShortcutAction)
            #if os(macOS)
            .focusedSceneValue(\.batchExport, browserModel.directory == nil ? nil : { showingBatchExport = true })
            .sheet(isPresented: $showingBatchExport) {
                if let directory = browserModel.directory { BatchExportView(directory: directory) }
            }
            #endif
            .toolbar {
                #if os(macOS)
                ToolbarItem(placement: .navigation) { fileBrowserToggle }
                #else
                ToolbarItem(placement: .topBarLeading) { fileBrowserToggle }
                #endif
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 12) {
                        Button(exporting ? "Preparing Image…" : "Export…", systemImage: "square.and.arrow.up") {
                            showingExportOptions = true
                        }
                        .keyboardShortcut("e", modifiers: [.command, .shift])
                        .disabled(development == nil || loading || exporting)
                        Button(savingRecipe ? "Saving Edits…" : savedRecipe == currentRecipe && !tutorialNeedsSave ? "Edits Saved" : "Save Edits", systemImage: "square.and.arrow.down") {
                            saveRecipe()
                        }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(development == nil || loading || savingRecipe || (savedRecipe == currentRecipe && !tutorialNeedsSave))
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
                        Button(hdrPreview ? "Preview: HDR" : "Preview: SDR") {
                            hdrPreview.toggle()
                            tutorial.previewToggled(hdr: hdrPreview)
                        }
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
            .sheet(isPresented: $showingPasteSettings, onDismiss: { browserPaste = nil }) {
                SettingsPasteOptions { selection in applyPastedSettings(selection, target: browserPaste) }
            }
            .sheet(isPresented: $showingExportOptions, onDismiss: { browserExport = nil }) {
                if let target = browserExport {
                    HEIFExportOptions(settings: $exportSettings, width: target.development.width,
                                      height: target.development.height, hdrEnabled: target.recipe.mapping.hdrEnabled,
                                      sourceURL: target.development.url, mapping: target.recipe.mapping,
                                      colorSpace: target.recipe.colorSpace,
                                      rawSettings: target.recipe.rawSettings ?? target.development.rawDefaults ?? RAWSettings(),
                                      save: { prepareExport(target) })
                } else if let development {
                    HEIFExportOptions(settings: $exportSettings, width: development.width,
                                      height: development.height, hdrEnabled: mapping.hdrEnabled,
                                      sourceURL: development.url, mapping: mapping, colorSpace: colorSpace,
                                      rawSettings: rawSettings, save: { prepareExport() })
                }
            }
            .fileExporter(isPresented: $showingSave, document: exportDocument,
                          contentType: exportContentType, defaultFilename: exportName) { result in
                switch result {
                case .success:
                    if exportedSourceURL?.standardizedFileURL == recipeSourceURL?.standardizedFileURL {
                        tutorial.record(.export)
                    }
                case .failure(let error): errorMessage = error.localizedDescription
                }
                exportDocument = nil
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
                switch result {
                case .success(let url):
                    requestDiscard { load(url, resetEdits: true) }
                case .failure(let error): errorMessage = error.localizedDescription
                }
            }
            .alert("Dark Melon", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
        .alert("Delete Edit?", isPresented: Binding(
            get: { deleteEditURL != nil }, set: { if !$0 { deleteEditURL = nil } }
        ), presenting: deleteEditURL) { url in
            Button("Delete Edit", role: .destructive) { deleteEdit(for: url) }
            Button("Cancel", role: .cancel) {}
        } message: { url in
            Text("Remove saved settings and discard pending edits for \(url.lastPathComponent)? The original image is kept. If Trash is unavailable, the settings sidecar is permanently deleted.")
        }
        .preferredColorScheme(.dark)
        .alert("Unsaved edits", isPresented: $confirmingDiscard) {
            Button("Save All and Continue") {
                do { try savePendingEdits(); finishTransition() }
                catch { errorMessage = error.localizedDescription; pendingTransition = nil }
            }
            Button("Discard Edits", role: .destructive) { finishTransition() }
            Button("Cancel", role: .cancel) { pendingTransition = nil }
        } message: {
            Text("There are unsaved edits for \(pendingEdits.entries.count) file(s). Save them or discard them before continuing.")
        }
        #if os(macOS)
        .background(FileSaveLifecycle(approveClose: confirmClose).frame(width: 0, height: 0))
        #endif
        #if os(macOS)
        .frame(minWidth: 1000, minHeight: 600)
        #endif
    }
    private func load(_ url: URL, resetEdits: Bool) {
        if resetEdits { rememberCurrentEdits() }
        sourceURL = url
        pendingAutoWhite = nil
        pendingAutoContrast = nil
        loading = true
        if resetEdits { mapping = ToneMapping(); savedRecipe = nil; recipeSourceURL = nil; baselineRecipe = nil }
        development = nil
        previewImages = nil
        histogram = nil
        previewRevision = UUID()
        Task {
            defer { loading = false }
            do {
                var restored: DevelopmentRecipe?
                let draft = resetEdits ? pendingEdits.entry(for: url) : nil
                if resetEdits {
                    do { restored = try await RecipeStore.shared.load(for: url) }
                    catch { errorMessage = "Could not restore saved edits: \(error.localizedDescription)" }
                    if let draft {
                        colorSpace = draft.recipe.colorSpace
                        mapping = draft.recipe.mapping
                        savedRecipe = draft.savedRecipe
                    } else if let restored {
                        colorSpace = restored.colorSpace
                        mapping = restored.mapping
                        savedRecipe = restored
                    } else {
                        colorSpace = try await developer.suggestedColorSpace(for: url)
                    }
                }
                let initializeEdits = resetEdits && restored == nil && draft == nil
                let options: RAWSettings? = resetEdits ? (draft?.recipe ?? restored)?.rawSettings : rawSettings
                developer = RAWDeveloper(colorSpace: colorSpace, rawSettings: options, rawWhiteBalance: mapping.rawWhiteBalance)
                histogramWorker = RAWDeveloper(colorSpace: colorSpace, rawSettings: options, rawWhiteBalance: mapping.rawWhiteBalance)
                exportWorker = RAWDeveloper(colorSpace: colorSpace, rawSettings: options, rawWhiteBalance: mapping.rawWhiteBalance)
                let loaded = try await developer.develop(url)
                if resetEdits {
                    let defaults = loaded.rawDefaults ?? RAWSettings()
                    rawSettings = options?.resolved(using: defaults) ?? defaults
                    if var saved = savedRecipe, loaded.isRAW {
                        saved.rawSettings = rawSettings
                        savedRecipe = saved
                    }
                }
                if loaded.isRAW, mapping.rawWhiteBalance == nil, let reference = loaded.whitePoint {
                    mapping.rawWhiteBalance = RAWWhiteBalance(reference)
                    if var saved = savedRecipe {
                        saved.mapping.rawWhiteBalance = mapping.rawWhiteBalance
                        savedRecipe = saved
                    }
                }
                if resetEdits {
                    if initializeEdits, !loaded.isRAW {
                        mapping.concentration = 0
                        if loaded.sourceHeadroom <= 1 { mapping.hdrGain = 0 }
                    }
                    hdrPreview = mapping.hdrEnabled
                }
                if resetEdits { baselineRecipe = draft?.baseline ?? currentRecipe }
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
        let worker = developer
        let existingHistogram = histogram
        let bins = histogramBins
        resettingTone = true
        Task {
            defer { resettingTone = false }
            do {
                let automatic = try await worker.automaticMapping(for: development, bins: bins,
                                                                  histogram: existingHistogram)
                guard self.development?.id == development.id, mapping == original else { return }
                mapping = SettingsPasteSelection(tone: true, whiteBalance: false, color: false,
                                                 hls: false, effects: false).applying(automatic, to: mapping)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func rememberCurrentEdits() {
        guard let url = recipeSourceURL, let baselineRecipe else { return }
        pendingEdits.remember(url: url, recipe: currentRecipe, baseline: baselineRecipe, saved: savedRecipe)
    }

    private func savePendingEdits() throws {
        rememberCurrentEdits()
        for entry in pendingEdits.entries {
            let saved = try RecipeStore.shared.saveSynchronously(entry.recipe, for: entry.url)
            pendingEdits.remove(entry.url)
            if entry.url == recipeSourceURL?.standardizedFileURL {
                savedRecipe = saved
                baselineRecipe = saved
                if mapping != saved.mapping {
                    mapping = saved.mapping
                    load(entry.url, resetEdits: false)
                }
                tutorial.record(.save)
            }
        }
    }

    private func requestDiscard(_ action: @escaping () -> Void) {
        rememberCurrentEdits()
        pendingTransition = action
        if pendingEdits.entries.isEmpty { finishTransition() }
        else { confirmingDiscard = true }
    }

    private func finishTransition() {
        let action = pendingTransition
        pendingTransition = nil
        pendingEdits.clear()
        // Prevent load from stashing the deliberately discarded current edits again.
        baselineRecipe = currentRecipe
        action?()
    }

    private func changeDirectory(_ url: URL, choose: Bool) {
        guard url.standardizedFileURL != browserModel.directory?.standardizedFileURL else {
            if choose { browserModel.choose(url) } else { browserModel.navigate(to: url) }
            return
        }
        requestDiscard {
            sourceURL = nil; recipeSourceURL = nil; baselineRecipe = nil; savedRecipe = nil
            development = nil; previewImages = nil; histogram = nil
            filename = "Dark Melon"
            if choose { browserModel.choose(url) } else { browserModel.navigate(to: url) }
        }
    }

    #if os(macOS)
    private func confirmClose() -> Bool {
        rememberCurrentEdits()
        guard !pendingEdits.entries.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = "Unsaved edits"
        alert.informativeText = "Save edits for \(pendingEdits.entries.count) file(s) before closing?"
        alert.addButton(withTitle: "Save All")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard Edits")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            do { try savePendingEdits(); return true }
            catch { NSAlert(error: error).runModal(); return false }
        case .alertThirdButtonReturn:
            return true
        default: return false
        }
    }
    #endif

    private func saveRecipe() {
        guard let sourceURL, development != nil, !loading else { return }
        let recipe = currentRecipe
        savingRecipe = true
        defer { savingRecipe = false }
        do {
            let saved = try RecipeStore.shared.saveSynchronously(recipe, for: sourceURL)
            savedRecipe = saved
            baselineRecipe = saved
            if mapping != saved.mapping {
                mapping = saved.mapping
                load(sourceURL, resetEdits: false)
            }
            pendingEdits.remove(sourceURL)
            tutorial.record(.save)
        } catch { errorMessage = "Could not save edits: \(error.localizedDescription) If folder access is denied, open the containing folder in the file browser and try again." }
    }

    private var histogramView: some View {
        LinearHistogram(development: development, histogram: histogram,
                        histogramError: histogramError, binCount: $histogramBins,
                        mapping: $mapping, sdrSource: previewImages?.sdr,
                        revision: previewRevision, colorSpace: colorSpace,
                        resettingTone: resettingTone, resetTone: resetTone,
                        showingSDR: $displayMode.sdrHistogram,
                        hoverPosition: hoveredPreviewPixel)
    }

    private func applyAutoTones() {
        guard autoTones, development != nil, !loading else { return }
        pendingAutoWhite = nil
        pendingAutoContrast = nil
        mapping = ToneSampleWhitePoint.automaticTones(mapping: mapping, space: colorSpace)
        mapping.setAutomaticHDRTarget()
    }

    private var tonePanel: some View {
    VStack(spacing: 0) {
        SlopeEditor(mapping: $mapping, autoTones: $autoTones,
           onToneChanged: { tutorial.record(.tone) },
           onContrastChanged: { tutorial.record(.contrast) },
           onContrastAdjustment: { hdrPreview = false },
           onHDRGainAdjustment: { hdrPreview = mapping.hdrEnabled }) { editing in
            adjustingTone = editing
            if !editing {
                toneLocatorImage = nil
                applyAutoTones()
                if development != nil, !loading { mapping.setAutomaticHDRTarget() }
            }
        }
        Divider()
        VectorscopeView(source: development?.preview,
                        hoverSource: previewImages?.sdr, hoverPosition: hoveredPreviewPixel,
                        hoverRevision: previewRevision,
                        revision: development?.id ?? previewRevision,
                        colorSpace: colorSpace, mapping: Binding(
                    get: { previewMapping },
                    set: { mapping.whiteBalance = $0.whiteBalance; mapping.rawWhiteBalance = $0.rawWhiteBalance }), pickingWhiteBalance: $pickingWhiteBalance,
                        resetRAWBalance: resetRAWWhiteBalanceAction,
                        convertWhiteBalance: convertWhiteBalanceAction, commitRAWBalance: commitRAWWhiteBalance)
    }
    }

    private var resetRAWWhiteBalanceAction: (() -> Void)? {
        guard development?.isRAW == true else { return nil }
        return {
            guard let sourceURL else { return }
            do {
                mapping.rawWhiteBalance = try RAWWhiteBalance.asShot(sourceURL)
                mapping.whiteBalance = WhiteBalance()
                commitRAWWhiteBalance()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func commitRAWWhiteBalance() {
        guard let sourceURL, !loading else { return }
        load(sourceURL, resetEdits: false)
    }

    private var convertWhiteBalanceAction: (() -> Void)? {
        guard development?.isRAW == true else { return nil }
        return { bakeWhiteBalanceIntoRAW() }
    }

    private func bakeWhiteBalanceIntoRAW() {
        guard let development, development.isRAW, !loading else { return }
        do {
            let baked = try RAWWhiteBalance.baked(currentRecipe, source: development.url)
            guard baked.mapping != mapping else { return }
            mapping = baked.mapping
            load(development.url, resetEdits: false)
        } catch { errorMessage = error.localizedDescription }
    }

    private var pickerShortcutAction: ((EditorPickerTool) -> Void)? {
        guard development != nil, !loading, !mapping.blackAndWhite.isEnabled else { return nil }
        return { togglePicker($0) }
    }

    private func togglePicker(_ tool: EditorPickerTool) {
        guard development != nil, !loading, !mapping.blackAndWhite.isEnabled else { return }
        if panel != .tone {
            pendingPicker = tool
            panel = .tone
            return
        }
        pickingWhiteBalance.toggle()
    }

    private var fileBrowserToggle: some View {
        Button(showingFileBrowser ? "Hide File Browser" : "Show File Browser", systemImage: "sidebar.left") {
            showingFileBrowser.toggle()
        }
        .labelStyle(.iconOnly)
        .keyboardShortcut("f", modifiers: [])
        .help(showingFileBrowser ? "Hide file browser (F)" : "Show file browser (F)")
        .accessibilityValue(showingFileBrowser ? "Shown" : "Hidden")
    }

    private func startTutorial() {
        tutorialPresented = true
        tutorial.start()
        showingFileBrowser = true
        panel = .tone
        hdrPreview = false
    }

    private func advanceTutorial() {
        tutorial.advance()
        if tutorial.step == .contrast || tutorial.step == .preview {
            hdrPreview = false
        }
        if tutorial.step == .tone || tutorial.step == .contrast { panel = .tone }
    }

    private func hasPendingEdit(_ url: URL) -> Bool {
        if url.standardizedFileURL == recipeSourceURL?.standardizedFileURL {
            return baselineRecipe != nil && currentRecipe != baselineRecipe
        }
        return pendingEdits.entry(for: url) != nil
    }

    private func performFileAction(_ action: BrowserFileAction, _ url: URL) {
        guard !fileActionBusy else { return }
        if action == .deleteEdit { deleteEditURL = url; return }
        if action == .showInFinder {
            #if os(macOS)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            #endif
            return
        }
        fileActionBusy = true
        Task {
            defer { fileActionBusy = false }
            do {
                let copied = action == .pasteEdit ? try SettingsClipboard.read() : nil
                let target: BrowserFileDevelopment
                if action != .export, let development,
                   development.url.standardizedFileURL == url.standardizedFileURL {
                    target = BrowserFileDevelopment(development: development, recipe: currentRecipe, worker: developer, savedRecipe: savedRecipe)
                } else {
                    // Export deliberately uses disk settings or automatic defaults.
                    let draft = action == .export ? nil : pendingEdits.entry(for: url)?.recipe
                    target = try await BrowserFileDevelopment.load(url, override: draft, bins: histogramBins)
                }
                switch action {
                case .copyEdit:
                    try SettingsClipboard.copy(target.recipe, reference: target.development.whitePoint, source: target.development.url)
                case .pasteEdit:
                    pastedSettings = copied
                    browserPaste = target
                    showingPasteSettings = true
                case .export:
                    browserExport = target
                    showingExportOptions = true
                case .deleteEdit, .showInFinder: break
                }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func applyPastedSettings(_ selection: SettingsPasteSelection, target: BrowserFileDevelopment?) {
        guard let pastedSettings, !loading else { return }
        if let target, target.development.url.standardizedFileURL != recipeSourceURL?.standardizedFileURL {
            let url = target.development.url
            let draft = pendingEdits.entry(for: url)
            let destination = draft?.recipe ?? target.recipe
            let updated = pastedSettings.applying(selection, to: destination.mapping,
                                                  reference: target.development.whitePoint, space: destination.colorSpace)
            pendingEdits.remember(url: url,
                recipe: DevelopmentRecipe(colorSpace: destination.colorSpace, mapping: updated,
                    rawSettings: selection.raw && target.development.isRAW
                        ? (pastedSettings.rawSettings?.resolved(using: target.development.rawDefaults ?? RAWSettings()) ?? destination.rawSettings)
                        : destination.rawSettings),
                baseline: draft?.baseline ?? target.recipe, saved: draft?.savedRecipe ?? target.savedRecipe)
        } else {
            guard development != nil else { return }
            pendingAutoWhite = nil
            pendingAutoContrast = nil
            comparingColor = false
            comparingHLS = false
            comparingEffects = false
            pickingWhiteBalance = false
            let previousRAWSettings = rawSettings
            if selection.raw, development?.isRAW == true, let copiedRAW = pastedSettings.rawSettings {
                rawSettings = copiedRAW.resolved(using: development?.rawDefaults ?? RAWSettings())
            }
            let previousRAWBalance = mapping.rawWhiteBalance
            mapping = pastedSettings.applying(selection, to: mapping, reference: development?.whitePoint, space: colorSpace)
            if mapping.rawWhiteBalance != previousRAWBalance || rawSettings != previousRAWSettings { commitRAWWhiteBalance() }
        }
    }

    private func deleteEdit(for url: URL) {
        fileActionBusy = true
        Task {
            defer { fileActionBusy = false }
            do {
                try await RecipeStore.shared.delete(for: url)
                pendingEdits.remove(url)
                if url.standardizedFileURL == recipeSourceURL?.standardizedFileURL {
                    // Explicit deletion has been confirmed; do not stash the discarded mapping again.
                    baselineRecipe = currentRecipe
                    load(url, resetEdits: true)
                }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func prepareExport(_ target: BrowserFileDevelopment? = nil) {
        guard let development = target?.development ?? development else { return }
        let settings = exportSettings
        let snapshot = target?.recipe.mapping ?? mapping
        let worker = target?.worker ?? exportWorker
        exportedSourceURL = development.url
        exporting = true
        exportContentType = settings.format.type
        exportName = development.url.deletingPathExtension().lastPathComponent + "." + settings.format.fileExtension
        Task {
            defer { exporting = false }
            do {
                let data = try await worker.exportHEIF(development.url, mapping: snapshot, settings: settings)
                exportDocument = HEIFDocument(data: data)
                showingSave = true
            } catch { errorMessage = error.localizedDescription }
        }
    }

}

/// Only valid preview/histogram combinations can be represented.
private enum PreviewHistogramMode {
    case hdrLinear, sdrLinear, sdrOutput

    var hdr: Bool {
        get { self == .hdrLinear }
        set {
            if newValue { self = .hdrLinear }
            else if self == .hdrLinear { self = .sdrLinear }
        }
    }

    var sdrHistogram: Bool {
        get { self == .sdrOutput }
        set {
            if newValue { self = .sdrOutput }
            else if self == .sdrOutput { self = .sdrLinear }
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
    @Binding var showingSDR: Bool
    let hoverPosition: CGPoint?
    @State private var hoverSampler = ScopeHoverSampler()
    @State private var hoveredRGB: SIMD3<Double>?
    @State private var sampledHover: HistogramHoverRequest?
    private var hoverRequest: HistogramHoverRequest {
        HistogramHoverRequest(position: hoverPosition,
                              revision: showingSDR ? revision : development?.id,
                              encoded: showingSDR, space: colorSpace)
    }
    private var hoverLuminance: Double? {
        guard sampledHover == hoverRequest, hoverPosition != nil, let rgb = hoveredRGB else { return nil }
        let weights = colorSpace.luminance
        // Linear Y for the source; encoded luma for SDR, matching its histogram statistics.
        return rgb.x * weights.x + rgb.y * weights.y + rgb.z * weights.z
    }
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
                Canvas { context, size in
                    guard let value = hoverLuminance else { return }
                    let x = min(size.width - 1, max(1, min(1, max(0, value)) * size.width))
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: 0))
                    line.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(line, with: .color(.black.opacity(0.9)), lineWidth: 3)
                    context.stroke(line, with: .color(.white),
                                   style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    let label = Text("Y" + (value < 0 ? "‹" : value > 1 ? "›" : ""))
                        .font(.caption2.bold())
                    let point = CGPoint(x: min(size.width - 12, max(12, x)), y: 9)
                    context.draw(label.foregroundStyle(.black), at: CGPoint(x: point.x + 1, y: point.y + 1))
                    context.draw(label.foregroundStyle(.white), at: point)
                }
                .allowsHitTesting(false)
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
        .task(id: hoverRequest) {
            let request = hoverRequest
            guard let position = request.position, let id = request.revision,
                  let source = showingSDR ? sdrSource : development?.preview else {
                hoveredRGB = nil
                return
            }
            do {
                let rgb = try await hoverSampler.sampleRGB(source, revision: id, position: position,
                                                           space: colorSpace, encoded: showingSDR)
                try Task.checkCancellation()
                hoveredRGB = rgb
                sampledHover = request
            } catch is CancellationError {
            } catch { hoveredRGB = nil }
        }
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



private struct ToneLocatorRequest: Equatable {
    let active: Bool
    let mapping: ToneMapping
    let revision: UUID
    let hdr: Bool
}


private struct HistogramHoverRequest: Equatable {
    let position: CGPoint?
    let revision: UUID?
    let encoded: Bool
    let space: ProcessingColorSpace
}
