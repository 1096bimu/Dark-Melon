import SwiftUI
import CoreImage
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.displayScale) private var displayScale
    @State private var previewCanvas = CGSize(width: 2560, height: 2560)
    @State private var renderedCanvas = CGSize.zero
    @State private var renderedMapping: ToneMapping?
    @State private var previewRegion: PreviewRegion?
    @State private var previewDetails: [PreviewDetail] = []
    @State private var detailWorker = RAWDeveloper()
    #if os(macOS)
    @State private var previewViewport = PreviewViewport()
    #endif
    @State private var cropPolygon: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
    @State private var cropTransform = CropTransform()
    @State private var cropping = false
    @State private var cropRatioPosition = 5.0
    @State private var editHistory = EditHistory()
    @State private var pendingEdits = PendingEdits()
    @State private var pendingControlsWidth: CGFloat = 120
    @State private var baselineRecipe: DevelopmentRecipe?
    @State private var pendingTransition: (() -> Void)?
    @State private var confirmingDiscard = false
    @State private var showingPasteSettings = false
    @State private var browserPaste: BrowserFileDevelopment?
    @State private var browserExport: BrowserFileDevelopment?
    @State private var fileActionBusy = false
    @State private var deleteEditURLs: [URL] = []
    @State private var pasteEditURLs: [URL] = []
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
    @State private var comparingOriginalMouse = false
    @State private var comparingOriginalKey = false
    @State private var comparingColor = false
    @State private var comparingEffects = false
    @State private var colorSpace = ProcessingColorSpace.sRGB
    @State private var sourceURL: URL?
    @State private var developer = RAWDeveloper()
    @State private var histogramWorker = RAWDeveloper()
    @State private var exportWorker = RAWDeveloper()
    @State private var histogramBins = 1
    @State private var histogram: HistogramData?
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
    @State private var adjustingWhitePoint = false
    @State private var toneLocatorImage: CGImage?
    @State private var previewRevision = UUID()
    @State private var filename = "Dark Melon"
    @State private var importing = false
    @State private var loading = false
    @State private var errorMessage: String?

    private var undoActions: EditorUndoActions {
        let _ = editHistory.revision
        return EditorUndoActions(canUndo: !loading && editHistory.canUndo,
            canRedo: !loading && editHistory.canRedo,
            undoTitle: editHistory.undoTitle, redoTitle: editHistory.redoTitle,
            undo: { commitHistory(); editHistory.undo() },
            redo: { editHistory.redo() })
    }

    private func commitHistory() {
        guard development != nil, !loading else { return }
        editHistory.observe(currentRecipe, name: cropping ? String(localized: "Transform") : nil)
        editHistory.flush()
    }

    private func restoreHistory(_ recipe: DevelopmentRecipe) {
        let reload = colorSpace != recipe.colorSpace || rawSettings != (recipe.rawSettings ?? rawSettings)
            || mapping.rawWhiteBalance != recipe.mapping.rawWhiteBalance
        cropping = false
        adjustingTone = false; adjustingWhitePoint = false; pickingWhiteBalance = false
        comparingColor = false; comparingEffects = false
        colorSpace = recipe.colorSpace
        mapping = recipe.mapping
        if let settings = recipe.rawSettings { rawSettings = settings }
        cropPolygon = mapping.transform?.points ?? [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
        if reload, let sourceURL { load(sourceURL, resetEdits: false) }
        rememberCurrentEdits()
    }

    private var comparingOriginal: Bool { comparingOriginalMouse || comparingOriginalKey }
    private var comparing: Bool { comparingOriginal || comparingColor || comparingEffects }
    private var originalMapping: ToneMapping {
        var result = ToneMapping.fresh(isRAW: development?.isRAW == true,
                                       sourceHeadroom: development?.sourceHeadroom ?? 1)
        result.rawWhiteBalance = mapping.rawWhiteBalance
        result.transform = mapping.transform
        return result
    }

    private var detailRequest: DetailPreviewRequest {
        let counterpart: ToneMapping? = comparing ? mapping
            : ([.color, .effects].contains(panel) ? comparisonMapping(panel) : originalMapping)
        return DetailPreviewRequest(sourceID: development?.id, mapping: previewMapping,
            counterpart: counterpart, comparing: comparing, hdr: hdrPreview,
            region: previewRegion, enabled: !loading && !cropping && !adjustingTone && !adjustingWhitePoint
                && (!editHistory.interacting || comparing))
    }

    private var visibleDetail: PreviewDetail? {
        guard !cropping, !adjustingTone, !adjustingWhitePoint,
              let detail = previewDetails.last(where: {
                  $0.sourceID == development?.id && $0.mapping == previewMapping && $0.hdr == hdrPreview
              }) else { return nil }
        // A cached patch covering the viewport can switch immediately, without
        // waiting for the background overview to finish rendering its counterpart.
        guard renderedMapping == previewMapping || previewRegion.map({ detail.rect.contains($0.rect) }) == true else { return nil }
        return detail
    }

    private var previewOutputSize: CGSize {
        let size = CGSize(width: development?.width ?? 1, height: development?.height ?? 1)
        return cropping ? size : previewMapping.transform?.resolution(width: Int(size.width), height: Int(size.height), estimate: .maximum) ?? size
    }

    private var tutorialNeedsSave: Bool {
        tutorial.active && tutorial.step == .save && !tutorial.fulfilled
    }

    private var currentRecipe: DevelopmentRecipe {
        var savedMapping = mapping
        if cropping, let transform = draftTransform { savedMapping.transform = transform }
        return DevelopmentRecipe(colorSpace: colorSpace, mapping: savedMapping, rawSettings: mapping.rawWhiteBalance == nil ? nil : rawSettings)
    }

    private var draftTransform: TransformSettings? {
        let result = TransformSettings(points: cropPolygon, ratioPosition: cropRatioPosition,
                                       rotation: cropTransform.rotation, horizontal: cropTransform.horizontal, vertical: cropTransform.vertical)
        return result.isValid ? result : nil
    }

    private func toggleTransform() {
        if cropping {
            mapping.transform = draftTransform
            cropping = false
        } else {
            if let saved = mapping.transform {
                cropRatioPosition = saved.ratioPosition
                cropTransform = CropTransform(rotation: saved.rotation, horizontal: saved.horizontal, vertical: saved.vertical)
                cropPolygon = saved.points
            }
            cropping = true
        }
    }

    private func resetTransform() {
        mapping.transform = nil
        cropTransform = CropTransform()
        cropPolygon = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
        cropping = false
        cropRatioPosition = 5
        #if os(macOS)
        previewViewport.zoom = 1
        previewViewport.offset = .zero
        #endif
    }

    private func originalPreviewPoint(_ point: CGPoint) -> CGPoint {
        guard !cropping, let transform = previewMapping.transform else { return point }
        let source = transform.sourcePoint(CGPoint(x: point.x, y: 1 - point.y))
        return CGPoint(x: source.x, y: 1 - source.y)
    }

    private func comparisonMapping(_ panel: EditorPanel) -> ToneMapping {
        var result = mapping
        if panel == .color {
            result.color = ColorAdjustments()
            result.vertexWarp = Array(repeating: OKLabVertexAdjustment(), count: 6)
            result.hls = Array(repeating: HLSAdjustment(), count: 6)
            result.blackAndWhite = BlackAndWhiteSettings()
            result.blackAndWhite.isEnabled = mapping.blackAndWhite.isEnabled
        }
        if panel == .effects { result.clarity = 0; result.hdf = 0; result.grain.strength = 0; result.halation.inputCurve = 0; result.vignette.amount = 0 }
        return result
    }

    private var previewMapping: ToneMapping {
        if comparingOriginal { return originalMapping }
        if comparingColor { return comparisonMapping(.color) }
        if comparingEffects { return comparisonMapping(.effects) }
        return mapping
    }

    var body: some View {
        NavigationStack {
            EditorColumns {
                if showingFileBrowser {
                    ImageFileBrowser(selectedURL: sourceURL, open: { load($0, resetEdits: true) }, model: browserModel, changeDirectory: changeDirectory,
                                     fileAction: performFileAction, multipleFileAction: performMultipleFileAction, hasPendingEdit: hasPendingEdit)
                        .frame(minWidth: 180, idealWidth: 220, maxWidth: 320)
                        .disabled(loading || fileActionBusy)
                        .overlay { if fileActionBusy { ProgressView("Preparing…").padding().background(.regularMaterial) } }
                }
            VStack(spacing: 0) {
                ZStack {
                    Color.black
                    if let previewImages {
                        #if os(macOS)
                        HDRImagePreview(image: ((adjustingTone || adjustingWhitePoint) ? toneLocatorImage : nil) ?? (cropping ? (hdrPreview ? previewImages.fullHDR : previewImages.fullSDR) : (hdrPreview ? previewImages.hdr : previewImages.sdr)),
                                        sourceSize: previewOutputSize, detail: visibleDetail,
                                        regionChanged: { previewRegion = $0 },
                                        hdr: hdrPreview, sourceID: development?.id ?? previewRevision,
                                        viewport: previewViewport,
                                        cropRatio: cropping ? CropGeometry.ratio(at: cropRatioPosition) : nil,
                                        cropTransform: $cropTransform,
                                        savedTransform: previewMapping.transform,
                                        cropChanged: { cropPolygon = $0 },
                                        sampleTool: pickingWhiteBalance ? .whiteBalance : nil,
                                        hover: { hoveredPreviewPixel = $0 }) { center, radius in
                            let sampleCenter = originalPreviewPoint(center)
                            let sampleEdge = originalPreviewPoint(CGPoint(x: center.x + radius, y: center.y))
                            let sourceRadius = hypot(sampleEdge.x - sampleCenter.x, sampleEdge.y - sampleCenter.y)
                            let sampledMapping = mapping
                            pickingWhiteBalance = false
                            guard let development else { return }
                            let sourceID = development.id
                            let worker = developer
                            Task {
                                do {
                                    let balance = try await worker.sampleWhiteBalance(development.preview, center: sampleCenter, radius: sourceRadius, mapping: sampledMapping)
                                    guard self.development?.id == sourceID, !loading, mapping == sampledMapping else { return }
                                    mapping.whiteBalance = balance
                                } catch { errorMessage = error.localizedDescription }
                            }
                        }
                            .padding(cropping ? 0 : 16)
                        #else
                        if cropping {
                            MobileCropPreview(image: hdrPreview ? previewImages.fullHDR : previewImages.fullSDR,
                                              hdr: hdrPreview, ratio: CropGeometry.ratio(at: cropRatioPosition), transform: $cropTransform, savedTransform: previewMapping.transform, cropChanged: { cropPolygon = $0 })
                        } else {
                        Image(decorative: ((adjustingTone || adjustingWhitePoint) ? toneLocatorImage : nil) ?? (cropping ? (hdrPreview ? previewImages.fullHDR : previewImages.fullSDR) : (hdrPreview ? previewImages.hdr : previewImages.sdr)), scale: 1)
                            .allowedDynamicRange(hdrPreview ? .high : .standard)
                            .resizable()
                            .scaledToFit()
                            .padding(16)
                        }
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
                .onGeometryChange(for: CGSize.self) { proxy in
                    // Quantize resize requests slightly, while covering Retina physical pixels.
                    CGSize(width: max(64, ceil((proxy.size.width - 32) * displayScale / 64) * 64),
                           height: max(64, ceil((proxy.size.height - 32) * displayScale / 64) * 64))
                } action: { previewCanvas = $0 }
                .overlay(alignment: .bottomLeading) {
                    if !cropping && !pendingEdits.entries.isEmpty {
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
                    if !cropping { HStack(spacing: 8) {
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
                }
                .overlay(alignment: .topTrailing) {
                    if let development {
                        CameraMetadataOverlay(metadata: development.metadata, whitePoint: development.whitePoint)
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if cropping { CropRatioControls(position: $cropRatioPosition) }
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
                        if panel == .transform {
                            TransformControls(cropping: cropping, image: previewImages?.fullSDR,
                                polygon: cropping ? cropPolygon : mapping.transform?.points ?? cropPolygon,
                                resolution: (cropping ? draftTransform : mapping.transform)?.resolution(width: development?.width ?? 1, height: development?.height ?? 1)
                                    ?? CGSize(width: development?.width ?? 1, height: development?.height ?? 1),
                                maximumResolution: (cropping ? draftTransform : mapping.transform)?.resolution(width: development?.width ?? 1, height: development?.height ?? 1, estimate: .maximum)
                                    ?? CGSize(width: development?.width ?? 1, height: development?.height ?? 1),
                                toggle: toggleTransform,
                                resetPerspective: { if !cropping { toggleTransform() }; cropTransform.horizontal = 0; cropTransform.vertical = 0 },
                                resetRotation: { if !cropping { toggleTransform() }; cropTransform.rotation = 0 },
                                resetAll: resetTransform)
                        } else if panel == .raw {
                            RAWControls(settings: $rawSettings, offset: $mapping.offset, isRAW: development?.isRAW == true, commit: {
                                if let sourceURL { load(sourceURL, resetEdits: false) }
                            }, reset: {
                                if let defaults = development?.rawDefaults, let sourceURL {
                                    mapping.offset = 0
                                    rawSettings = defaults
                                    load(sourceURL, resetEdits: false)
                                }
                            })
                        } else if panel == .color {
                            ColorControls(settings: $mapping.color, vertices: $mapping.vertexWarp, comparing: $comparingColor, monochrome: mapping.blackAndWhite.isEnabled, hdrMax: mapping.hdrMax, colorSpace: colorSpace)
                        } else if panel == .effects {
                            EffectsControls(clarity: $mapping.clarity, radius: $mapping.clarityRadius, hdf: $mapping.hdf, hdfRadius: $mapping.hdfRadius, grain: $mapping.grain, halation: $mapping.halation, vignette: $mapping.vignette, hdrEnabled: mapping.hdrEnabled, comparing: $comparingEffects)
                        } else {
                            tonePanel
                        }
                    }
                    .disabled(loading || development == nil)
                }
                .frame(minWidth: 320, idealWidth: 360, maxWidth: 480)
            }
            .task {
                editHistory.restore = restoreHistory
                if !tutorialPresented {
                    tutorialPresented = true
                    startTutorial()
                }
            }
            .onChange(of: currentRecipe) { old, new in
                guard !loading, development != nil, !cropping else { return }
                editHistory.observe(new, name: EditHistory.actionName(from: old, to: new))
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
                if panel != .transform, cropping { mapping.transform = draftTransform; cropping = false }
                pickingWhiteBalance = false
                adjustingTone = false
                adjustingWhitePoint = false
                toneLocatorImage = nil
                comparingColor = false
                comparingEffects = false
                let requested = pendingPicker
                pendingPicker = nil
                if panel == .tone, let requested { togglePicker(requested) }
            }
            .onChange(of: development?.id) { _, _ in
                comparingOriginalMouse = false
                comparingOriginalKey = false
                pendingPicker = nil
                pickingWhiteBalance = false
                adjustingTone = false
                adjustingWhitePoint = false
                toneLocatorImage = nil
                comparingColor = false
                comparingEffects = false
            }
            .onChange(of: mapping.white) { _, _ in
                if !loading { hdrPreview = false }
            }
            .task(id: ToneLocatorRequest(active: adjustingTone || adjustingWhitePoint, clipping: adjustingWhitePoint, mapping: previewMapping,
                                         revision: previewRevision, hdr: hdrPreview)) {
                guard adjustingTone || adjustingWhitePoint, development != nil, let previewImages else { return }
                do {
                    let image = try await developer.toneLocator(previewImages.source,
                        preview: hdrPreview ? previewImages.fullHDR : previewImages.fullSDR,
                        mapping: previewMapping, hdr: hdrPreview, clipping: adjustingWhitePoint)
                    try Task.checkCancellation()
                    toneLocatorImage = image
                } catch is CancellationError {
                } catch { errorMessage = error.localizedDescription }
            }
            .task(id: PreviewRequest(mapping: previewMapping,
                                     sourceID: development?.id, loading: loading, canvas: previewCanvas)) {
                guard let development, !loading else { return }
                do {
                    let renderedMapping = previewMapping
                    let canvas = previewCanvas
                    if canvas != renderedCanvas { try await Task.sleep(for: .milliseconds(100)) }
                    let source = try await developer.overview(development, canvas: canvas)
                    let images = try await developer.previews(source, mapping: renderedMapping)
                    try Task.checkCancellation()
                    previewImages = images
                    self.renderedMapping = renderedMapping
                    renderedCanvas = canvas
                    previewRevision = UUID()

                } catch is CancellationError {
                    // A newer drag position supersedes this render.
                } catch { errorMessage = error.localizedDescription }
            }
            .task(id: detailRequest) {
                let request = detailRequest
                guard request.enabled, let development, let region = request.region else { return }
                do {
                    if !request.comparing { try await Task.sleep(for: .milliseconds(200)) }
                    let output = request.mapping.transform?.resolution(width: development.width, height: development.height, estimate: .maximum)
                        ?? CGSize(width: development.width, height: development.height)
                    let overview = previewImages?.source ?? development.preview
                    let overviewScale = Double(overview.width) / Double(development.width)
                    if PreviewResolution.requiredScale(display: region.displayPixels, output: output) <= overviewScale * 1.01 {
                        previewDetails.removeAll()
                        return
                    }
                    // Render the visible state first, then warm the active panel's comparison.
                    let states = [request.mapping] + (request.counterpart.map { [$0] } ?? [])
                    for state in states {
                        if previewDetails.contains(where: { $0.covers(region, sourceID: development.id,
                            mapping: state, hdr: request.hdr, outputSize: output) }) { continue }
                        let detail = try await detailWorker.detail(development, mapping: state, hdr: request.hdr, region: region)
                        try Task.checkCancellation()
                        previewDetails.removeAll { $0.sourceID == detail.sourceID && $0.mapping == state && $0.hdr == detail.hdr }
                        previewDetails.append(detail)
                        if previewDetails.count > 2 { previewDetails.removeFirst(previewDetails.count - 2) }
                    }
                } catch is CancellationError {
                } catch {
                    // Detail is an optional refinement; retain the usable overview on failure.
                }
            }
            .task(id: HistogramRequest(sourceID: development?.id, loading: loading, previewReady: previewImages != nil, bins: histogramBins)) {
                histogramError = nil
                guard let development, !loading, previewImages != nil else {
                    histogram = nil
                    return
                }
                do {
                    try await Task.sleep(for: .milliseconds(180))
                    let result = try await histogramWorker.buildHistogram(development, bins: histogramBins)
                    try Task.checkCancellation()
                    histogram = result

                } catch is CancellationError {
                } catch { histogramError = error.localizedDescription }
            }
            .background(EditGestureBoundary(began: {
                editHistory.flush()
                editHistory.interacting = true
            }, ended: {
                editHistory.interacting = false
                if !cropping { commitHistory() }
            }))
            .background(OriginalCompareShortcut(active: $comparingOriginalKey,
                enabled: development != nil && !loading && !cropping))
            .navigationTitle(filename)
            .focusedSceneValue(\.editorUndo, undoActions)
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
                #if !os(macOS)
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Undo", systemImage: "arrow.uturn.backward", action: undoActions.undo)
                        .disabled(!undoActions.canUndo)
                    Button("Redo", systemImage: "arrow.uturn.forward", action: undoActions.redo)
                        .disabled(!undoActions.canRedo)
                }
                #endif
                ToolbarItemGroup(placement: .principal) {
                    Button(exporting ? "Preparing Image…" : "Export…", systemImage: "square.and.arrow.up") {
                        showingExportOptions = true
                    }
                    .labelStyle(.iconOnly)
                    .help("Export…")
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(development == nil || loading || exporting)
                    Button(savingRecipe ? "Saving Edits…" : savedRecipe == currentRecipe && !tutorialNeedsSave ? "Edits Saved" : "Save Edits", systemImage: "square.and.arrow.down") {
                        saveRecipe()
                    }
                    .labelStyle(.iconOnly)
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
                    .labelsHidden()
                    .fixedSize()
                    .disabled(loading || exporting)
                    Toggle("HDR", isOn: Binding(get: { hdrPreview }, set: { enabled in
                        hdrPreview = enabled
                        tutorial.previewToggled(hdr: enabled)
                    }))
                        .toggleStyle(.button)
                        .keyboardShortcut("h", modifiers: [])
                        .disabled(!mapping.hdrEnabled)
                        .help("Toggle HDR or SDR display of the developed image")
                        .accessibilityValue(hdrPreview ? "HDR" : "SDR")
                }
                ToolbarItem(placement: .primaryAction) {
                    Picker("Panel", selection: $panel) {
                        ForEach(EditorPanel.allCases) { panel in Text(LocalizedStringKey(panel.rawValue)).tag(panel) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            .sheet(isPresented: $showingPasteSettings, onDismiss: { browserPaste = nil; pasteEditURLs = [] }) {
                SettingsPasteOptions { selection in
                    if pasteEditURLs.isEmpty { applyPastedSettings(selection, target: browserPaste) }
                    else { pasteMultipleEdits(selection, urls: pasteEditURLs) }
                }
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
                                      sourceURL: development.url, mapping: currentRecipe.mapping, colorSpace: colorSpace,
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
        .alert("Delete Edits?", isPresented: Binding(
            get: { !deleteEditURLs.isEmpty }, set: { if !$0 { deleteEditURLs = [] } }
        ), presenting: deleteEditURLs) { urls in
            Button("Delete Edits", role: .destructive) { deleteEdits(for: urls) }
            Button("Cancel", role: .cancel) {}
        } message: { urls in
            Text("Remove saved settings and discard pending edits for \(urls.count) file(s)? Original images are kept. If Trash is unavailable, settings sidecars are permanently deleted.")
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
        #if os(macOS)
        if resetEdits { SidecarFolderAccess.shared.requestIfNeeded(for: url) }
        #endif
        commitHistory()
        if resetEdits { rememberCurrentEdits() }
        if resetEdits { cropping = false; cropRatioPosition = 5; cropTransform = CropTransform(); cropPolygon = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)] }
        sourceURL = url
        loading = true
        if resetEdits { mapping = ToneMapping(); savedRecipe = nil; recipeSourceURL = nil; baselineRecipe = nil }
        development = nil
        previewImages = nil
        previewDetails.removeAll()
        renderedMapping = nil
        histogram = nil
        previewRevision = UUID()
        Task {
            defer {
                if recipeSourceURL == url, development != nil {
                    editHistory.activate(url, recipe: currentRecipe)
                }
                loading = false
            }
            do {
                var restored: DevelopmentRecipe?
                let draft = resetEdits ? pendingEdits.entry(for: url) : nil
                if resetEdits {
                    do { restored = try await RecipeStore.shared.load(for: url) }
                    catch { errorMessage = String(localized: "Could not restore saved edits: \(error.localizedDescription)") }
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
                detailWorker = RAWDeveloper(colorSpace: colorSpace)
                let loaded = try await developer.develop(url, previewCanvas: previewCanvas)
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
                        if loaded.sourceHeadroom <= 1 { mapping.hdrGain = 0 }
                    }
                    hdrPreview = mapping.hdrEnabled
                }
                if resetEdits {
                    cropPolygon = mapping.transform?.points ?? cropPolygon
                    baselineRecipe = draft?.baseline ?? currentRecipe
                }
                recipeSourceURL = url
                development = loaded

                filename = url.lastPathComponent
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func resetTone() {
        guard let development, !loading, !resettingTone else { return }
        commitHistory()
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
                                                 effects: false, raw: false).applying(automatic, to: mapping)
                editHistory.observe(currentRecipe, name: String(localized: "Reset Tone"))
                editHistory.flush()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func rememberCurrentEdits() {
        guard let url = recipeSourceURL, let baselineRecipe else { return }
        pendingEdits.remember(url: url, recipe: currentRecipe, baseline: baselineRecipe, saved: savedRecipe)
    }

    private func savePendingEdits() throws {
        commitHistory()
        rememberCurrentEdits()
        for entry in pendingEdits.entries {
            #if os(macOS)
            guard SidecarFolderAccess.shared.requestIfNeeded(for: entry.url) else {
                throw CocoaError(.userCancelled)
            }
            #endif
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
        editHistory.clear()
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
        alert.messageText = String(localized: "Unsaved edits")
        alert.informativeText = String(localized: "Save edits for \(pendingEdits.entries.count) file(s) before closing?")
        alert.addButton(withTitle: String(localized: "Save All"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Discard Edits"))
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
        commitHistory()
        guard let sourceURL, development != nil, !loading else { return }
        let recipe = currentRecipe
        savingRecipe = true
        defer { savingRecipe = false }
        do {
            #if os(macOS)
            guard SidecarFolderAccess.shared.requestIfNeeded(for: sourceURL) else { return }
            #endif
            let saved = try RecipeStore.shared.saveSynchronously(recipe, for: sourceURL)
            savedRecipe = saved
            baselineRecipe = saved
            if mapping != saved.mapping {
                mapping = saved.mapping
                load(sourceURL, resetEdits: false)
            }
            pendingEdits.remove(sourceURL)
            tutorial.record(.save)
        } catch { errorMessage = String(localized: "Could not save edits: \(error.localizedDescription) If folder access is denied, open the containing folder in the file browser and try again.") }
    }

    private var histogramView: some View {
        LinearHistogram(development: development, histogram: histogram,
                        histogramError: histogramError, binCount: $histogramBins,
                        mapping: $mapping, sdrSource: previewImages?.sdr,
                        revision: previewRevision, colorSpace: colorSpace,
                        comparingOriginal: $comparingOriginalMouse,
                        showingSDR: $displayMode.sdrHistogram,
                        hoverPosition: displayMode.sdrHistogram ? hoveredPreviewPixel : hoveredPreviewPixel.map(originalPreviewPoint),
                        onWhitePointEditingChanged: { editing in
                            adjustingWhitePoint = editing
                            toneLocatorImage = nil
                        })
    }

    private func applyAutoTones() {
        guard autoTones, development != nil, !loading else { return }
        mapping = ToneSampleWhitePoint.automaticTones(mapping: mapping, space: colorSpace)
        mapping.setAutomaticHDRTarget()
    }

    private var tonePanel: some View {
    VStack(spacing: 0) {
        HStack {
            Text("Tone").font(.headline)
            Spacer()
            Button("Reset Tone", action: resetTone).disabled(resettingTone)
        }.padding(12)
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
            if baked.mapping.whiteBalance != WhiteBalance() {
                errorMessage = String(localized: "White balance limits reached. The remaining adjustment has been retained in RGB gains.")
            }
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
        if action == .deleteEdit { deleteEditURLs = [url]; return }
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
        commitHistory()
        if let target, target.development.url.standardizedFileURL != recipeSourceURL?.standardizedFileURL {
            let url = target.development.url
            let draft = pendingEdits.entry(for: url)
            let destination = draft?.recipe ?? target.recipe
            let updated = pastedSettings.applying(selection, to: destination.mapping,
                                                  reference: target.development.whitePoint, space: destination.colorSpace)
            let updatedRecipe = DevelopmentRecipe(colorSpace: destination.colorSpace, mapping: updated,
                rawSettings: selection.raw && target.development.isRAW
                    ? (pastedSettings.rawSettings?.resolved(using: target.development.rawDefaults ?? RAWSettings()) ?? destination.rawSettings)
                    : destination.rawSettings)
            editHistory.record(url, from: destination, to: updatedRecipe, name: String(localized: "Paste Edits"))
            pendingEdits.remember(url: url, recipe: updatedRecipe,
                baseline: draft?.baseline ?? target.recipe, saved: draft?.savedRecipe ?? target.savedRecipe)
        } else {
            guard development != nil else { return }
                    comparingColor = false
            comparingEffects = false
            pickingWhiteBalance = false
            let previousRAWSettings = rawSettings
            if selection.raw, development?.isRAW == true, let copiedRAW = pastedSettings.rawSettings {
                rawSettings = copiedRAW.resolved(using: development?.rawDefaults ?? RAWSettings())
            }
            let previousRAWBalance = mapping.rawWhiteBalance
            mapping = pastedSettings.applying(selection, to: mapping, reference: development?.whitePoint, space: colorSpace)
            editHistory.observe(currentRecipe, name: String(localized: "Paste Edits"))
            editHistory.flush()
            if mapping.rawWhiteBalance != previousRAWBalance || rawSettings != previousRAWSettings { commitRAWWhiteBalance() }
        }
    }

    private func performMultipleFileAction(_ action: BrowserFileAction, urls: [URL]) {
        guard !fileActionBusy, !urls.isEmpty else { return }
        if action == .deleteEdit { deleteEditURLs = urls; return }
        do {
            pastedSettings = try SettingsClipboard.read()
            pasteEditURLs = urls
            browserPaste = nil
            showingPasteSettings = true
        } catch { errorMessage = error.localizedDescription }
    }

    private func pasteMultipleEdits(_ selection: SettingsPasteSelection, urls: [URL]) {
        fileActionBusy = true
        Task {
            defer { fileActionBusy = false }
            var failures: [String] = []
            // Apply the current image last: RAW changes may start an editor reload.
            for url in urls where url.standardizedFileURL != recipeSourceURL?.standardizedFileURL {
                do {
                    let target = try await BrowserFileDevelopment.load(url,
                        override: pendingEdits.entry(for: url)?.recipe, bins: histogramBins)
                    applyPastedSettings(selection, target: target)
                } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            if urls.contains(where: { $0.standardizedFileURL == recipeSourceURL?.standardizedFileURL }) {
                applyPastedSettings(selection, target: nil)
            }
            if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
        }
    }

    private func deleteEdits(for urls: [URL]) {
        fileActionBusy = true
        Task {
            defer { fileActionBusy = false }
            var failures: [String] = []
            var reloadCurrent = false
            for url in urls {
                do {
                    try await RecipeStore.shared.delete(for: url)
                    editHistory.remove(url)
                    pendingEdits.remove(url)
                    if url.standardizedFileURL == recipeSourceURL?.standardizedFileURL { reloadCurrent = true }
                } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            if reloadCurrent, let url = recipeSourceURL {
                baselineRecipe = currentRecipe
                load(url, resetEdits: true)
            }
            if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
        }
    }

    private func prepareExport(_ target: BrowserFileDevelopment? = nil) {
        guard let development = target?.development ?? development else { return }
        let settings = exportSettings
        let snapshot = target?.recipe.mapping ?? currentRecipe.mapping
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
    @Binding var comparingOriginal: Bool
    @Binding var showingSDR: Bool
    let hoverPosition: CGPoint?
    var onWhitePointEditingChanged: (Bool) -> Void = { _ in }
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
                HoldCompareButton(comparing: $comparingOriginal, title: "Compare Original")
                    .disabled(development == nil)
                    .help("Hold to compare with default development settings. Hold C for the same preview.")
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
                if !showingSDR { HistogramPoints(mapping: $mapping, onWhitePointEditingChanged: onWhitePointEditingChanged) }
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
    let canvas: CGSize
}

private struct DetailPreviewRequest: Equatable {
    let sourceID: UUID?
    let mapping: ToneMapping
    let counterpart: ToneMapping?
    let comparing: Bool
    let hdr: Bool
    let region: PreviewRegion?
    let enabled: Bool
}



private struct HistogramRequest: Equatable {
    let sourceID: UUID?
    let loading: Bool
    let previewReady: Bool
    let bins: Int
}

private struct SDRHistogramRequest: Equatable {
    let revision: UUID
    let bins: Int
    let space: ProcessingColorSpace
}



private struct ToneLocatorRequest: Equatable {
    let active: Bool
    let clipping: Bool
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
