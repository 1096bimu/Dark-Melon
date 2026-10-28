import SwiftUI
import Combine
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
    @State private var fullSourceWorker = RAWDeveloper(interactive: true)
    @State private var interactiveSpace: ProcessingColorSpace?
    #if os(macOS)
    @State private var previewViewport = PreviewViewport()
    #endif
    @State private var cropPolygon: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
    @State private var cropTransform = CropTransform()
    @State private var cropping = false
    @State private var cropRatioPosition = 5.0
    @State private var editHistory = EditHistory()
    @State private var deferredEditBefore: DevelopmentRecipe?
    @State private var pendingEdits = PendingEdits()
    @State private var pendingControlsWidth: CGFloat = 120
    @State private var baselineRecipe: DevelopmentRecipe?
    @State private var pendingTransition: (() -> Void)?
    @State private var pendingCancelTransition: (() -> Void)?
    @State private var confirmingDiscard = false
    @State private var showingPasteSettings = false
    @State private var confirmingPreset: PresetApplication?
    @State private var presetPreview: PresetPreview?
    @State private var presetShowingBefore = false
    @State private var presetPreviewError: String?
    private func copyCurrentDevelopmentSettings() {
        do {
            if let sourceURL {
                try SettingsClipboard.copy(currentRecipe, reference: development?.whitePoint, source: sourceURL)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func pasteDevelopmentSettings() {
        do {
            pastedSettings = try SettingsClipboard.read()
            browserPaste = nil
            showingPasteSettings = true
        } catch { errorMessage = error.localizedDescription }
    }

    private var activePresetPreview: PresetPreview? {
        presetPreview?.id == confirmingPreset?.id ? presetPreview : nil
    }
    private var previewDevelopment: RAWDevelopment? {
        if let activePresetPreview, !presetShowingBefore { return activePresetPreview.development }
        return development
    }
    @State private var browserPaste: BrowserRecipeTarget?
    @State private var exportSession: (development: RAWDevelopment, recipe: DevelopmentRecipe)?
    @State private var fileActionBusy = false
    @State private var deleteEditURLs: [URL] = []
    @State private var pasteEditURLs: [URL] = []
    @State private var exportedSourceURL: URL?
    @State private var resettingTone = false
    @State private var browserModel = ImageBrowserModel(remembersFolder: true)
    @State private var showingFileBrowser = true
    @State private var showingMetadata = true
    @State private var leftPanelWidth: CGFloat = BrowserGridLayout.twoColumnWidth
    @AppStorage("leftPanel.library") private var showingLibrary = false
    #if os(macOS)
    @State private var showingBatchExport = false
    @State private var exportQueue = ExportQueue.shared
    @State private var showingExportQueue = false
    @State private var pendingSingleExport: (plan: ExportPlan, worker: RAWDeveloper)?
    @State private var exportPresentationWindow: NSWindow?
    #endif
    @State private var pastedSettings: CopiedSettings?
    @State private var recipeSourceURL: URL?
    @State private var savedSnapshotDate: Date?
    @State private var namedSnapshots: [NamedSnapshot] = []
    @State private var snapshotSessions: [URL: SnapshotSession] = [:]
    @State private var snapshotAppliedRecipe: DevelopmentRecipe?
    private var snapshotSession: SnapshotSession {
        get { recipeSourceURL.flatMap { snapshotSessions[$0.standardizedFileURL] } ?? SnapshotSession() }
        nonmutating set {
            if let recipeSourceURL { snapshotSessions[recipeSourceURL.standardizedFileURL] = newValue }
        }
    }
    @State private var savedRecipe: DevelopmentRecipe?
    @State private var savingRecipe = false
    @State private var rawSettings = RAWSettings()
    @State private var maximizingRAWRange = false
    @State private var panel = EditorPanel.tone
    @State private var comparingOriginalMouse = false
    @State private var comparingOriginalKey = false
    @State private var comparingColor = false
    @State private var comparingEffects = false
    @State private var colorSpace = ProcessingColorSpace.sRGB
    @State private var sourceURL: URL?
    @State private var developer = RAWDeveloper()
    @State private var histogramWorker = RAWDeveloper()
    @State private var histogramBins = 1
    @State private var histogram: HistogramData?
    @State private var histogramError: String?
    @State private var exportSettings = HEIFSettings.restored()
    @State private var showingExportOptions = false
    @State private var variationExportMode = false
    @AppStorage("variationExport.grid") private var variationGrid = 2
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
    @State private var previewHover = PreviewHoverState()
    @State private var displayMode = PreviewHistogramMode.hdrLinear
    private var hdrPreview: Bool {
        get { !comparingOriginal && displayMode.hdr }
        nonmutating set { displayMode.hdr = newValue }
    }
    @State private var renderedPreviewImages: PreviewImages?
    private var previewImages: PreviewImages? {
        if let activePresetPreview { return presetShowingBefore ? activePresetPreview.before : activePresetPreview.after }
        return renderedPreviewImages
    }
    @State private var adjustingTone = false
    @State private var adjustingWhitePoint = false
    @State private var toneLocatorImage: CGImage?
    @State private var previewRevision = UUID()
    @State private var lutRevision = 0
    @State private var filename = "Dark Melon"
    @State private var importing = false
    @State private var showingFilmLock = false
    @State private var lockedFilm: FilmSettings?
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
        finishDeferredEdit()
        editHistory.observe(currentRecipe, name: cropping ? String(localized: "Transform") : nil)
        editHistory.flush()
    }

    private func restoreHistory(_ recipe: DevelopmentRecipe) {
        var applied = recipe
        applied.draftSnapshot = snapshotSession.persistedDraft
        snapshotAppliedRecipe = applied
        namedSnapshots = recipe.snapshots
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

    @State private var asShotBalance: RAWWhiteBalance?

    @State private var defaultsCache = EditorDefaultsCache()
    private var resetDefaults: DevelopmentRecipe {
        defaultsCache.resolve(space: colorSpace, isRAW: development?.isRAW == true,
            headroom: development?.sourceHeadroom ?? 1, raw: development?.rawDefaults,
            balance: asShotBalance, preset: EditLibrary.shared.rawDefaultPreset)
    }

    private var comparingOriginal: Bool { comparingOriginalMouse || comparingOriginalKey }
    private var comparing: Bool { comparingOriginal || comparingColor || comparingEffects }
    private var originalMapping: ToneMapping {
        var result = resetDefaults.mapping
        if mapping.color.monochrome {
            result.color.monochrome = true
            OKLabVertexWarp.setMonochrome(true, controls: &result.vertexWarp)
        }
        // hdrPreview selects SDR while comparing; retain the preset's gain for
        // effects and LUTs that depend on HDR even when viewing their SDR result.
        result.rawWhiteBalance = mapping.rawWhiteBalance
        result.transform = mapping.transform
        return result
    }

    private var detailRequest: DetailPreviewRequest {
        let counterpart: ToneMapping? = confirmingPreset != nil ? nil : comparing ? mapping
            : ([.color, .effects].contains(panel) ? comparisonMapping(panel) : originalMapping)
        return DetailPreviewRequest(sourceID: previewDevelopment?.id, mapping: previewMapping,
            counterpart: counterpart, comparing: comparing || confirmingPreset != nil, hdr: hdrPreview,
            region: previewRegion, enabled: previewDevelopment?.fullResolutionReady == true && !loading && !cropping && !adjustingTone && !adjustingWhitePoint
                && (!editHistory.interacting || comparing))
    }

    private var visibleDetail: PreviewDetail? {
        guard !cropping, !adjustingTone, !adjustingWhitePoint,
              let detail = previewDetails.last(where: {
                  $0.sourceID == previewDevelopment?.id && $0.mapping == previewMapping && $0.hdr == hdrPreview
              }) else { return nil }
        // A cached patch covering the viewport can switch immediately, without
        // waiting for the background overview to finish rendering its counterpart.
        guard renderedMapping == previewMapping || previewRegion.map({ detail.rect.contains($0.rect) }) == true else { return nil }
        return detail
    }

    private var previewOutputSize: CGSize {
        let size = CGSize(width: previewDevelopment?.width ?? 1, height: previewDevelopment?.height ?? 1)
        return cropping ? size : previewMapping.transform?.resolution(width: Int(size.width), height: Int(size.height), estimate: .maximum) ?? size
    }

    private var tutorialNeedsSave: Bool {
        tutorial.active && tutorial.step == .save && !tutorial.fulfilled
    }

    private var currentRecipe: DevelopmentRecipe {
        var savedMapping = mapping
        if cropping, let transform = draftTransform { savedMapping.transform = transform }
        return DevelopmentRecipe(colorSpace: colorSpace, mapping: savedMapping, rawSettings: mapping.rawWhiteBalance == nil ? nil : rawSettings, snapshots: namedSnapshots, draftSnapshot: snapshotSession.persistedDraft)
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
        let transform = resetDefaults.mapping.transform
        mapping.transform = transform
        cropTransform = CropTransform(rotation: transform?.rotation ?? 0, horizontal: transform?.horizontal ?? 0, vertical: transform?.vertical ?? 0)
        cropPolygon = transform?.points ?? [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
        cropping = false
        cropRatioPosition = transform?.ratioPosition ?? 5
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
            result.color.monochrome = mapping.color.monochrome
            result.vertexWarp = OKLabVertexWarp.defaults
            result.hls = Array(repeating: HLSAdjustment(), count: 6)
            result.blackAndWhite = BlackAndWhiteSettings()
            result.blackAndWhite.isEnabled = mapping.blackAndWhite.isEnabled
        }
        if panel == .effects { result.channelContrast = [0, 0, 0]; result.dyeMixers = DyeMixers(); result.clarity = 0; result.hdf = 0; result.grain.strength = 0; result.halation.inputCurve = 0; result.vignette.amount = 0; result.badHDR = BadHDRSettings() }
        return result
    }

    private var previewMapping: ToneMapping {
        if let activePresetPreview { return presetShowingBefore ? mapping : activePresetPreview.recipe.mapping }
        if comparingOriginal { return originalMapping }
        if comparingColor { return comparisonMapping(.color) }
        if comparingEffects { return comparisonMapping(.effects) }
        return mapping
    }

    private var libraryPanel: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                EditLibraryView(current: development == nil || loading ? nil : currentRecipe, selectedLUT: $mapping.lutID, filename: filename) { name, recipe, selection in
                    commitHistory()
                    confirmingPreset = PresetApplication(name: name, recipe: recipe, selection: selection)
                }.frame(height: max(0, geometry.size.height / 2))
                .popover(item: $confirmingPreset, arrowEdge: .leading) { preset in
                    PresetConfirmation(preset: preset, isRAW: development?.isRAW == true,
                        comparing: $presetShowingBefore, ready: activePresetPreview != nil,
                        error: presetPreviewError) {
                        pastedSettings = CopiedSettings(mapping: preset.recipe.mapping,
                            rawSettings: preset.recipe.rawSettings)
                        if let activePresetPreview {
                            renderedPreviewImages = activePresetPreview.after
                            renderedMapping = activePresetPreview.recipe.mapping
                        }
                        applyPastedSettings(preset.selection, target: nil)
                    }
                    .presentationCompactAdaptation(.popover)
                }
                Divider()
                EditSnapshotsView(saved: savedRecipe != nil, savedAt: savedSnapshotDate, draftAt: snapshotSession.draftModifiedAt, draft: snapshotSession.draft != nil,
                    snapshots: namedSnapshots, selected: snapshotSession.selected,
                    select: selectSnapshot, create: createSnapshot, update: updateSnapshot, delete: deleteSnapshot, discardDraft: discardSnapshotDraft)
                    .disabled(development == nil || loading)
                    .frame(maxHeight: .infinity)
            }
        }
        .onDisappear { confirmingPreset = nil }
    }

    private func preparePresetPreview() async {
        presetPreview = nil
        presetPreviewError = nil
        presetShowingBefore = false
        guard let preset = confirmingPreset, let development else { return }
        do {
            let cached = renderedMapping == mapping ? renderedPreviewImages : nil
            let result = try await PresetPreview.prepare(preset, original: currentRecipe,
                development: development, canvas: previewCanvas, cachedBefore: cached)
            try Task.checkCancellation()
            presetPreview = result
            previewRevision = UUID()
        } catch is CancellationError {
        } catch { presetPreviewError = error.localizedDescription }
    }

    private var editorColumns: some View {
    EditorColumns {
        if showingFileBrowser {
            Group {
                if showingLibrary {
                    libraryPanel
                } else {
            ImageFileBrowser(selectedURL: sourceURL, open: { load($0, resetEdits: true) }, model: browserModel, changeDirectory: changeDirectory,
                             fileAction: performFileAction, multipleFileAction: performMultipleFileAction, pendingURLs: browserPendingURLs)
                .disabled(loading || fileActionBusy)
                .overlay { if fileActionBusy { ProgressView("Preparing…").padding().background(.regularMaterial) } }
                }
            }
            .frame(minWidth: 180, idealWidth: leftPanelWidth, maxWidth: 320)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                if showingFileBrowser, (180...320).contains(width) {
                    leftPanelWidth = width
                }
            }

        }
    VStack(spacing: 0) {
        ZStack {
            Color.black
            if let previewImages {
                #if os(macOS)
                HDRImagePreview(sdrImage: cropping ? previewImages.fullSDR : previewImages.sdr,
                                image: ((adjustingTone || adjustingWhitePoint) ? toneLocatorImage : nil) ?? (cropping ? (hdrPreview ? previewImages.fullHDR : previewImages.fullSDR) : (hdrPreview ? previewImages.hdr : previewImages.sdr)),
                                surface: (adjustingTone || adjustingWhitePoint) ? nil : (cropping
                                    ? (hdrPreview ? previewImages.fullSurfaceHDR : previewImages.fullSurfaceSDR)
                                    : (hdrPreview ? previewImages.surfaceHDR : previewImages.surfaceSDR)),
                                sdrSurface: cropping ? previewImages.fullSurfaceSDR : previewImages.surfaceSDR,
                                sourceSize: previewOutputSize, detail: visibleDetail,
                                regionChanged: { previewRegion = $0 },
                                hdr: hdrPreview, sourceID: previewDevelopment?.id ?? previewRevision,
                                viewport: previewViewport,
                                cropRatio: cropping ? CropGeometry.ratio(at: cropRatioPosition) : nil,
                                cropTransform: $cropTransform,
                                savedTransform: previewMapping.transform,
                                cropChanged: { cropPolygon = $0 },
                                sampleTool: pickingWhiteBalance ? .whiteBalance : nil,
                                hover: { previewHover.position = $0 }) { center, radius in
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
                    .modifier(HDRScreenSaver())
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
                .modifier(PreviewOverlayVisibility())
                .padding(.leading, 12).padding(.bottom, 64)
                .disabled(loading)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !cropping { HStack(spacing: 8) {
                Button("Copy", systemImage: "doc.on.doc") { copyCurrentDevelopmentSettings() }
                .focusedSceneValue(\.copyDevelopmentSettings,
                                   development == nil || loading ? nil : { copyCurrentDevelopmentSettings() })
                .help("Copy all development settings")
                Button("Paste", systemImage: "doc.on.clipboard") { pasteDevelopmentSettings() }
                .focusedSceneValue(\.pasteDevelopmentSettings,
                                   development == nil || loading ? nil : { pasteDevelopmentSettings() })
                .help("Choose which development settings to paste")
            }
            .buttonStyle(.bordered)
            .labelStyle(.titleOnly)
            .fixedSize()
            .padding(10)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
            .modifier(PreviewOverlayVisibility())
            .padding(12)
            .disabled(development == nil || loading)
            }
        }
        .overlay(alignment: .topTrailing) {
            if showingMetadata, let development {
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
                if panel == .color {
                    ColorPanelHeader(settings: $mapping.color, vertices: $mapping.vertexWarp,
                        comparing: $comparingColor).padding(12)
                    HueChromaScope(controls: $mapping.vertexWarp, monochrome: $mapping.color.monochrome, source: mapping.color.monochrome ? development?.preview : (hdrPreview ? previewImages?.hdr : previewImages?.sdr),
                        revision: mapping.color.monochrome ? development?.id ?? previewRevision : previewRevision, space: colorSpace,
                        headroom: previewMapping.hdrMax, hdr: hdrPreview,
                        hoverTransform: mapping.color.monochrome && !cropping ? previewMapping.transform : nil)
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
                        resetPerspective: { if !cropping { toggleTransform() }; cropTransform.horizontal = resetDefaults.mapping.transform?.horizontal ?? 0; cropTransform.vertical = resetDefaults.mapping.transform?.vertical ?? 0 },
                        resetRotation: { if !cropping { toggleTransform() }; cropTransform.rotation = resetDefaults.mapping.transform?.rotation ?? 0 },
                        resetAll: resetTransform).filmLock(.transform)
                } else if panel == .raw {
                    RAWControls(settings: $rawSettings, offset: $mapping.offset, isRAW: development?.isRAW == true, commit: {
                        if let sourceURL { load(sourceURL, resetEdits: false) }
                    }, reset: {
                        if let defaults = resetDefaults.rawSettings, let sourceURL {
                            mapping.offset = resetDefaults.mapping.offset
                            rawSettings = defaults
                            load(sourceURL, resetEdits: false)
                        }
                    }, maximizingRange: maximizingRAWRange, maxRange: maximizeRAWRange)
                } else if panel == .color {
                    ColorControls(settings: $mapping.color, vertices: $mapping.vertexWarp, monochrome: mapping.blackAndWhite.isEnabled || mapping.color.monochrome, hdrMax: mapping.hdrMax, colorSpace: colorSpace)
                } else if panel == .effects {
                    EffectsControls(badHDR: $mapping.badHDR, dyeMixers: $mapping.dyeMixers, randomizeDye: { strength in
                        let generation = DyeMixers.Generation(seed: UInt64.random(in: .min ... .max),
                            strength: UInt16((strength.clamped(to: 0...3) / 3 * 65535).rounded()))
                        if let candidate = DyeMixers.seeded(generation) {
                            mapping.dyeMixers = candidate
                        }
                    }, channelContrast: $mapping.channelContrast, clarity: $mapping.clarity, radius: $mapping.clarityRadius, hdf: $mapping.hdf, hdfRadius: $mapping.hdfRadius, grain: $mapping.grain, halation: $mapping.halation, vignette: $mapping.vignette, hdrEnabled: mapping.hdrEnabled, monochrome: mapping.color.monochrome, comparing: $comparingEffects)
                } else {
                    tonePanel
                }
            }
            .disabled(loading || development == nil)
        }
        .frame(minWidth: 320, idealWidth: 320, maxWidth: 480)
    }
    }

    private var editorScene: some View {
        editorColumns
            .focusedSceneValue(\.editorUndo, undoActions)
            .focusedSceneValue(\.editorPanel, $panel)
            .focusedSceneValue(\.imageInfoVisible, $showingMetadata)
            .focusedSceneValue(\.startTutorial, { startTutorial() })
            .focusedSceneValue(\.toggleEditorPicker, pickerShortcutAction)
            #if os(macOS)
            .focusedSceneValue(\.variationExport, development == nil || loading ? nil : { beginExportOptions(variation: true) })
            .focusedSceneValue(\.batchExport, browserModel.directory == nil ? nil : { showingBatchExport = true })
            #endif
    }

    var body: some View {
        NavigationStack {
            editorScene
            .environment(\.lockedFilmItems, lockedFilm?.selection.selectedItems ?? [])
            .environment(\.resetMapping, resetDefaults.mapping)
            .environment(\.resetRAWSettings, resetDefaults.rawSettings)
            .task {
                browserModel.restoreLastFolder()
                editHistory.restore = restoreHistory
                editHistory.captureSession = { snapshotSession }
                editHistory.restoreSession = { snapshotSession = $0 }
                if !tutorialPresented {
                    tutorialPresented = true
                    startTutorial()
                }
            }
            .onChange(of: currentRecipe) { old, new in
                guard !loading, development != nil, !cropping else { return }
                if snapshotAppliedRecipe == new {
                    snapshotAppliedRecipe = nil
                    return
                }
                snapshotAppliedRecipe = nil
                if editHistory.interacting {
                    if deferredEditBefore == nil { deferredEditBefore = old }
                    return
                }
                let before = deferredEditBefore ?? old
                deferredEditBefore = nil
                recordRecipeChange(from: before, to: new)
                rememberCurrentEdits()
            }
            .onChange(of: recipeSourceURL) { _, _ in
                if tutorial.active { tutorial.resetForImage() }
            }
            .onChange(of: exportSettings) { _, settings in settings.remember() }
            .onChange(of: mapping.color.monochrome) { _, _ in pickingWhiteBalance = false }
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
            .onChange(of: mapping.white) { _, white in
                if mapping.tonePosition > white {
                    mapping.tonePosition = white
                    mapping.setAutomaticHDRTarget()
                }
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
            .task(id: confirmingPreset?.id) { await preparePresetPreview() }
            .onChange(of: presetShowingBefore) { _, _ in previewRevision = UUID() }
            .onReceive(NotificationCenter.default.publisher(for: .lutConfigurationChanged).receive(on: DispatchQueue.main)) { notification in
                guard notification.object as? UUID == previewMapping.lutID else { return }
                lutRevision += 1
            }
            .task(id: PreviewRequest(mapping: previewMapping,
                                     sourceID: development?.id, loading: loading, canvas: previewCanvas, lutRevision: lutRevision)) {
                guard let development, !loading, confirmingPreset == nil else { return }
                do {
                    let renderedMapping = previewMapping
                    let canvas = previewCanvas
                    if canvas != renderedCanvas { try await Task.sleep(for: .milliseconds(100)) }
                    let source = try await developer.overview(development, canvas: canvas)
                    let images = try await developer.previews(source, mapping: renderedMapping)
                    try Task.checkCancellation()
                    renderedPreviewImages = images
                    self.renderedMapping = renderedMapping
                    renderedCanvas = canvas
                    previewRevision = UUID()

                } catch is CancellationError {
                    // A newer drag position supersedes this render.
                } catch { errorMessage = error.localizedDescription }
            }
            .task(id: FullSourceRequest(source: development?.id, previewReady: renderedPreviewImages != nil, loading: loading)) {
                guard !loading, renderedPreviewImages != nil, let current = development,
                      !current.fullResolutionReady else { return }
                // A separate actor keeps decoding from blocking overview edits and hover work.
                let worker = fullSourceWorker
                do {
                    let full = try await worker.prepareFullResolution(current)
                    try Task.checkCancellation()
                    guard development?.id == current.id else { return }
                    development = full
                } catch is CancellationError {
                } catch { errorMessage = error.localizedDescription }
            }
            .task(id: detailRequest) {
                let request = detailRequest
                guard request.enabled, let development = previewDevelopment, let region = request.region else { return }
                let renderer: RAWDeveloper = (presetShowingBefore ? nil : activePresetPreview?.worker) ?? detailWorker
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
                        let detail = try await renderer.detail(development, mapping: state, hdr: request.hdr, region: region)
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
            .environment(previewHover)
            .background(EditGestureBoundary(began: {
                finishDeferredEdit()
                editHistory.flush()
                if !loading, development != nil, !cropping { deferredEditBefore = currentRecipe }
                editHistory.interacting = true
            }, ended: {
                editHistory.interacting = false
                if !cropping { commitHistory() }
            }))
            .background(OriginalCompareShortcut(active: $comparingOriginalKey,
                enabled: development != nil && !loading && !cropping))
            .background(leftPanelShortcuts.opacity(0).frame(width: 0, height: 0).accessibilityHidden(true))
            #if os(macOS)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                editHistory.interacting = false
                if !cropping { commitHistory() }
            }
            .background(FileNavigationShortcut(navigate: navigateFile).frame(width: 0, height: 0))
            #endif
            .navigationTitle(filename)
            #if os(macOS)
            .sheet(isPresented: $showingBatchExport) {
                if let directory = browserModel.directory { BatchExportView(directory: directory, film: lockedFilm, recipeOverrides: batchRecipeOverrides, pendingURLs: browserPendingURLs, queue: exportQueue) }
            }
            #endif
            .toolbar {
                #if os(macOS)
                ToolbarItem(placement: .navigation) { leftPanelPicker }
                #else
                ToolbarItem(placement: .topBarLeading) { leftPanelPicker }
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
                        beginExportOptions()
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
                    Toggle("Film Lock", systemImage: lockedFilm == nil ? "lock.open" : "lock.fill", isOn: Binding(
                        get: { lockedFilm != nil },
                        set: {
                            confirmingPreset = nil
                            if $0 { requestFilmLock() } else { lockedFilm = nil }
                        }))
                        .toggleStyle(.button)
                        .disabled(loading || (development == nil && lockedFilm == nil))
                        .help("Capture film settings and apply them as unsaved edits when opening another photo. Unlock to stop applying them.")
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
                    .disabled(loading)
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
                #if os(macOS)
                if !exportQueue.jobs.isEmpty {
                    ToolbarItem {
                        Button("Exports", systemImage: exportQueue.symbol) {
                            showingExportQueue.toggle()
                        }
                        .labelStyle(.iconOnly)
                        .help("Exports")
                        .popover(isPresented: $showingExportQueue) { ExportQueueView(queue: exportQueue) }
                    }
                }
                #endif
                ToolbarItem(placement: .primaryAction) {
                    Picker("Panel", selection: $panel) {
                        ForEach(EditorPanel.allCases) { panel in Text(LocalizedStringKey(panel.rawValue)).tag(panel) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            .sheet(isPresented: $showingFilmLock) {
                SettingsPasteOptions(apply: { selection in
                    lockedFilm = FilmSettings(mapping, rawSettings: mapping.rawWhiteBalance == nil ? nil : rawSettings, selection: selection)
                }, title: "Film Lock", actionTitle: "Lock", selectingLock: true)
            }
            .sheet(isPresented: $showingPasteSettings, onDismiss: { browserPaste = nil; pasteEditURLs = [] }) {
                SettingsPasteOptions { selection in
                    if pasteEditURLs.isEmpty { applyPastedSettings(selection, target: browserPaste) }
                    else { pasteMultipleEdits(selection, urls: pasteEditURLs) }
                }
            }
            .sheet(isPresented: $showingExportOptions, onDismiss: {
                exportSession = nil
                #if os(macOS)
                let window = exportPresentationWindow
                exportPresentationWindow = nil
                if let prepared = pendingSingleExport {
                    pendingSingleExport = nil
                    chooseExportDestination(prepared.plan, worker: prepared.worker, window: window)
                }
                #endif
            }) {
                if let session = exportSession {
                    HEIFExportOptions(settings: $exportSettings, width: session.development.width,
                                      height: session.development.height, hdrEnabled: session.recipe.mapping.hdrEnabled,
                                      sourceURL: session.development.url, mapping: session.recipe.mapping,
                                      colorSpace: session.recipe.colorSpace,
                                      rawSettings: session.recipe.rawSettings ?? session.development.rawDefaults ?? RAWSettings(),
                                      variationGrid: variationExportMode ? $variationGrid : nil,
                                      save: { prepareExport(development: session.development, recipe: session.recipe, worker: $0) })
                }
            }
            .fileExporter(isPresented: $showingSave, document: exportDocument,
                          contentType: exportContentType, defaultFilename: exportName) { (result: Result<URL, Error>) in
                finishFileExport(result)
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { (result: Result<URL, Error>) in
                switch result {
                case .success(let url):
                    requestDiscard { load(url, resetEdits: true) }
                case .failure(let error): errorMessage = error.localizedDescription
                }
            }
            #if !os(macOS)
            .onOpenURL { url in
                guard url.isFileURL else { return }
                requestDiscard { load(url, resetEdits: true) }
            }
            #endif
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
                catch {
                    if (error as? CocoaError)?.code == .userCancelled { cancelTransition() }
                    else {
                        errorMessage = error.localizedDescription
                        pendingTransition = nil
                        pendingCancelTransition = nil
                    }
                }
            }
            Button("Discard Edits", role: .destructive) { finishTransition() }
            Button("Cancel", role: .cancel) { cancelTransition() }
        } message: {
            if pendingCancelTransition != nil {
                Text("Save or discard pending edits before Film Lock, or choose Cancel to keep them unsaved and continue using the current edit.")
            } else {
                Text("There are unsaved edits for \(pendingEdits.entries.count) file(s). Save them or discard them before continuing.")
            }
        }
        #if os(macOS)
        .background(FileSaveLifecycle(approveClose: confirmClose, openFile: { url in
            requestDiscard { load(url, resetEdits: true) }
        }).frame(width: 0, height: 0))
        #endif
        #if os(macOS)
        .frame(minWidth: 1000, minHeight: 600)
        #endif
    }
    private func load(_ url: URL, resetEdits: Bool, onLoaded: (() -> Void)? = nil) {
        #if os(macOS)
        if resetEdits { SidecarFolderAccess.shared.requestIfNeeded(for: url) }
        #endif
        commitHistory()
        if resetEdits { confirmingPreset = nil; rememberCurrentEdits() }
        if resetEdits { cropping = false; cropRatioPosition = 5; cropTransform = CropTransform(); cropPolygon = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)] }
        sourceURL = url
        loading = true
        if resetEdits { mapping = ToneMapping(); savedRecipe = nil; recipeSourceURL = nil; baselineRecipe = nil; namedSnapshots = []; savedSnapshotDate = nil }
        // A same-file RAW rebuild keeps the existing display alive. The preview
        // task replaces it only after the new source has been decoded and rendered.
        if resetEdits {
            development = nil
            renderedPreviewImages = nil
            previewDetails.removeAll()
            renderedMapping = nil
            histogram = nil
            previewRevision = UUID()
        }
        Task {
            defer {
                if recipeSourceURL == url, development != nil {
                    editHistory.activate(url, recipe: currentRecipe)
                }
                loading = false
                if recipeSourceURL == url, development != nil {
                    if resetEdits { applyLockedFilm() }
                    onLoaded?()
                }
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
                if resetEdits {
                    namedSnapshots = (draft?.recipe ?? restored)?.snapshots ?? []
                    savedSnapshotDate = (try? RecipeStore.sidecarURL(for: url).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                }
                let initializeEdits = resetEdits && restored == nil && draft == nil
                var options: RAWSettings? = resetEdits ? (draft?.recipe ?? restored)?.rawSettings : rawSettings
                var initialRecipe: DevelopmentRecipe?
                if initializeEdits {
                    let preset = EditLibrary.shared.rawDefaultPreset
                    let target = try await BrowserRecipeTarget.fresh(url)
                    let resolver = RAWDeveloper(colorSpace: colorSpace)
                    var recipe = try await resolver.resolveExportRecipe(url, recipe: target.recipe, isRAW: target.isRAW,
                        maximizeRange: UserDefaults.standard.bool(forKey: RAWSettings.maximizeRangePreferenceKey))
                    if target.isRAW, let preset { recipe = preset.applying(to: recipe) }
                    initialRecipe = recipe
                    options = recipe.rawSettings
                    mapping = recipe.mapping
                }
                if resetEdits || interactiveSpace != colorSpace {
                    developer = RAWDeveloper(colorSpace: colorSpace, rawSettings: options, rawWhiteBalance: mapping.rawWhiteBalance, interactive: true)
                    fullSourceWorker = RAWDeveloper(colorSpace: colorSpace, rawSettings: options, rawWhiteBalance: mapping.rawWhiteBalance, interactive: true)
                    detailWorker = RAWDeveloper(colorSpace: colorSpace, interactive: true)
                    interactiveSpace = colorSpace
                } else {
                    await developer.updateRAWSettings(options, whiteBalance: mapping.rawWhiteBalance)
                    await fullSourceWorker.updateRAWSettings(options, whiteBalance: mapping.rawWhiteBalance)
                }
                histogramWorker = RAWDeveloper(colorSpace: colorSpace, rawSettings: options, rawWhiteBalance: mapping.rawWhiteBalance)
                let loaded = try await developer.develop(url, previewCanvas: CGSize(width: 2560, height: 2560), progressive: true)
                let defaults = loaded.rawDefaults ?? RAWSettings()
                rawSettings = options?.resolved(using: defaults) ?? defaults
                if resetEdits {
                    if var saved = savedRecipe, loaded.isRAW {
                        saved.rawSettings = rawSettings
                        savedRecipe = saved
                    }
                }
                if initializeEdits {
                    mapping = initialRecipe?.mapping ?? ToneMapping.fresh(isRAW: loaded.isRAW, sourceHeadroom: loaded.sourceHeadroom)
                }
                if loaded.isRAW, mapping.rawWhiteBalance == nil, let reference = loaded.whitePoint {
                    mapping.rawWhiteBalance = RAWWhiteBalance(reference)
                    if var saved = savedRecipe {
                        saved.mapping.rawWhiteBalance = mapping.rawWhiteBalance
                        savedRecipe = saved
                    }
                }
                if resetEdits {
                    hdrPreview = mapping.hdrEnabled
                }
                if resetEdits {
                    cropPolygon = mapping.transform?.points ?? cropPolygon
                }
                recipeSourceURL = url
                if resetEdits {
                    let storedDraft = (draft?.recipe ?? restored)?.draftSnapshot
                    snapshotSession = draft?.session ?? SnapshotSession(selected: draft == nil ? "saved" : "unsaved",
                        draft: storedDraft?.edit ?? draft.map { SnapshotEdit($0.recipe) },
                        draftModifiedAt: storedDraft?.modifiedAt ?? draft?.modifiedAt)
                    baselineRecipe = draft?.baseline ?? currentRecipe
                }
                if resetEdits { asShotBalance = loaded.isRAW ? try? RAWWhiteBalance.asShot(url) : nil }
                previewDetails.removeAll()
                development = loaded

                filename = url.lastPathComponent
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func applyLockedFilm() {
        guard let lockedFilm else { return }
        let updated = lockedFilm.applying(to: currentRecipe)
        guard updated.mapping != mapping || updated.rawSettings != currentRecipe.rawSettings else { return }
        let reload = updated.mapping.rawWhiteBalance != mapping.rawWhiteBalance || updated.rawSettings != currentRecipe.rawSettings
        mapping = updated.mapping
        if let raw = updated.rawSettings { rawSettings = raw }
        var session = snapshotSession
        session.draft = baselineRecipe.map { SnapshotEdit($0) == SnapshotEdit(currentRecipe) } == true
            ? nil : SnapshotEdit(currentRecipe)
        session.draftModifiedAt = session.draft == nil ? nil : Date()
        session.selected = session.draft == nil ? "saved" : "unsaved"
        snapshotSession = session
        // Register the transfer against the loaded edit, not against a new baseline.
        snapshotAppliedRecipe = currentRecipe
        editHistory.observe(currentRecipe, name: String(localized: "Film Lock"))
        editHistory.flush()
        rememberCurrentEdits()
        if reload, let sourceURL { load(sourceURL, resetEdits: false) }
    }

    private func resetTone() {
        guard let development, !loading, !resettingTone else { return }
        commitHistory()
        let original = mapping
        let originalRAW = rawSettings
        let maximizeRange = UserDefaults.standard.bool(forKey: RAWSettings.maximizeRangePreferenceKey)
        let preset = development.isRAW ? EditLibrary.shared.rawDefaultPreset : nil
        let worker = RAWDeveloper(colorSpace: colorSpace, rawSettings: originalRAW, rawWhiteBalance: mapping.rawWhiteBalance)
        resettingTone = true
        Task {
            defer { resettingTone = false }
            do {
                var resetRAW = originalRAW
                if development.isRAW {
                    if maximizeRange { resetRAW = try await worker.maximumRAWRange(development.url) }
                    else { resetRAW.values[.exposure] = 0 }
                    if let preset, preset.selection.contains(.exposure), let exposure = preset.recipe.rawSettings?.values[.exposure] {
                        resetRAW.values[.exposure] = exposure
                    }
                }
                guard self.development?.id == development.id, mapping == original,
                      rawSettings == originalRAW else { return }
                var baseline = DevelopmentRecipe(colorSpace: colorSpace,
                    mapping: .fresh(isRAW: development.isRAW, sourceHeadroom: development.sourceHeadroom))
                if let preset { baseline = preset.applying(to: baseline) }
                let automatic = baseline.mapping
                mapping = SettingsPasteSelection(tone: true, whiteBalance: false, color: false,
                                                 effects: false, raw: false).applying(automatic, to: mapping)
                rawSettings = resetRAW
                // Record before reloading so the decoder refresh cannot swallow
                // the reset's unsaved snapshot or split it into separate undo steps.
                var session = snapshotSession
                session.draft = baselineRecipe.map { SnapshotEdit($0) == SnapshotEdit(currentRecipe) } == true
                    ? nil : SnapshotEdit(currentRecipe)
                session.draftModifiedAt = session.draft == nil ? nil : Date()
                session.selected = session.draft == nil ? "saved" : "unsaved"
                snapshotSession = session
                snapshotAppliedRecipe = currentRecipe
                editHistory.observe(currentRecipe, name: String(localized: "Reset Tone"))
                editHistory.flush()
                rememberCurrentEdits()
                if development.isRAW, resetRAW != originalRAW {
                    load(development.url, resetEdits: false)
                }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func selectSnapshot(_ key: String) {
        guard !loading, key != snapshotSession.selected else { return }
        commitHistory()
        let edit: SnapshotEdit?
        if key == "saved" { edit = savedRecipe.map(SnapshotEdit.init) }
        else if key == "unsaved" { edit = snapshotSession.draft }
        else { edit = namedSnapshots.first { $0.id.uuidString == key }?.edit }
        guard let edit else { return }
        var session = snapshotSession
        session.selected = key
        snapshotSession = session
        var recipe = edit.recipe
        recipe.snapshots = namedSnapshots
        restoreHistory(recipe)
        editHistory.observe(currentRecipe, name: String(localized: "Switch Snapshot"))
        editHistory.flush()
    }

    private func createSnapshot(_ name: String) {
        commitHistory()
        let item = NamedSnapshot(name: name, edit: SnapshotEdit(currentRecipe))
        namedSnapshots.append(item)
        var session = snapshotSession
        session.selected = item.id.uuidString
        snapshotSession = session
        snapshotAppliedRecipe = currentRecipe
        editHistory.observe(currentRecipe, name: String(localized: "Create Snapshot"))
        editHistory.flush()
        rememberCurrentEdits()
    }

    private func updateSnapshot(_ key: String) {
        guard !loading, development != nil else { return }
        if key == "saved" { saveRecipe(); return }
        commitHistory()
        var session = snapshotSession
        if key == "unsaved" {
            session.draft = SnapshotEdit(currentRecipe)
            session.draftModifiedAt = Date()
        } else {
            guard let index = namedSnapshots.firstIndex(where: { $0.id.uuidString == key }) else { return }
            namedSnapshots[index].edit = SnapshotEdit(currentRecipe)
            namedSnapshots[index].createdAt = Date()
        }
        session.selected = key
        snapshotSession = session
        snapshotAppliedRecipe = currentRecipe
        editHistory.observe(currentRecipe, name: String(localized: "Update with Current"))
        editHistory.flush()
        rememberCurrentEdits()
    }

    private func deleteSnapshot(_ id: UUID) {
        commitHistory()
        namedSnapshots.removeAll { $0.id == id }
        var session = snapshotSession
        if session.selected == id.uuidString {
            session.selected = "unsaved"
            session.draft = SnapshotEdit(currentRecipe)
            session.draftModifiedAt = Date()
        }
        snapshotSession = session
        snapshotAppliedRecipe = currentRecipe
        editHistory.observe(currentRecipe, name: String(localized: "Delete Snapshot"))
        editHistory.flush()
        rememberCurrentEdits()
    }

    private func discardSnapshotDraft() {
        commitHistory()
        var session = snapshotSession
        let restoreSaved = session.selected == "unsaved"
        session.draft = nil
        session.draftModifiedAt = nil
        if restoreSaved { session.selected = "saved" }
        snapshotSession = session
        if restoreSaved, let recipe = savedRecipe ?? baselineRecipe {
            var restored = recipe
            restored.snapshots = namedSnapshots
            restoreHistory(restored)
        } else {
            snapshotAppliedRecipe = currentRecipe
        }
        editHistory.observe(currentRecipe, name: String(localized: "Discard Unsaved Edit"))
        editHistory.flush()
        rememberCurrentEdits()
    }

    /// During a gesture only the rendering mapping changes. Commit snapshot,
    /// history, and browser state together at the boundary, or before leaving.
    private func recordRecipeChange(from old: DevelopmentRecipe, to new: DevelopmentRecipe) {
        if SnapshotEdit(old) != SnapshotEdit(new) {
            var session = snapshotSession
            session.draft = baselineRecipe.map { SnapshotEdit($0) == SnapshotEdit(new) } == true ? nil : SnapshotEdit(new)
            session.draftModifiedAt = session.draft == nil ? nil : Date()
            session.selected = session.draft == nil ? "saved" : "unsaved"
            snapshotSession = session
        }
        editHistory.observe(currentRecipe, name: EditHistory.actionName(from: old, to: new))
    }

    private func finishDeferredEdit() {
        guard let before = deferredEditBefore else { return }
        deferredEditBefore = nil
        guard before != currentRecipe else { return }
        recordRecipeChange(from: before, to: currentRecipe)
        // The snapshot metadata change must not be mistaken for another edit.
        snapshotAppliedRecipe = currentRecipe
        guard let url = recipeSourceURL, let baselineRecipe else { return }
        pendingEdits.remember(url: url, recipe: currentRecipe, baseline: baselineRecipe,
            saved: savedRecipe, session: snapshotSession)
    }

    private func rememberCurrentEdits() {
        finishDeferredEdit()
        guard let url = recipeSourceURL, let baselineRecipe else { return }
        pendingEdits.remember(url: url, recipe: currentRecipe, baseline: baselineRecipe,
            saved: savedRecipe, session: snapshotSession)
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
            var session = entry.session ?? SnapshotSession(selected: "unsaved")
            let saved = try RecipeStore.shared.saveSynchronously(session.recipeForSaving(entry.recipe), for: entry.url)
            session.didSave(saved)
            snapshotSessions[entry.url] = session
            pendingEdits.remove(entry.url)
            if entry.url == recipeSourceURL?.standardizedFileURL {
                savedRecipe = saved
                savedSnapshotDate = Date()
                baselineRecipe = saved
                snapshotSession = session
                namedSnapshots = saved.snapshots
                restoreHistory(saved)
                editHistory.seed(saved)
                tutorial.record(.save)
            }
        }
    }

    private func requestFilmLock() {
        commitHistory()
        rememberCurrentEdits()
        guard !pendingEdits.entries.isEmpty else {
            showingFilmLock = true
            return
        }
        requestDiscard(onCancel: { showingFilmLock = true }) {
            guard let url = recipeSourceURL else { return }
            // Reload the resolved state: discarded edits must not be captured as film.
            load(url, resetEdits: true) { showingFilmLock = true }
        }
    }

    private func requestDiscard(onCancel: (() -> Void)? = nil, _ action: @escaping () -> Void) {
        rememberCurrentEdits()
        pendingCancelTransition = onCancel
        pendingTransition = action
        if pendingEdits.entries.isEmpty { finishTransition() }
        else { confirmingDiscard = true }
    }

    private func cancelTransition() {
        let action = pendingCancelTransition
        pendingTransition = nil
        pendingCancelTransition = nil
        // Film Lock can capture the active edit without saving, discarding, or reloading it.
        action?()
    }

    private func finishTransition() {
        let action = pendingTransition
        pendingTransition = nil
        pendingCancelTransition = nil
        pendingEdits.clear()
        snapshotSessions.removeAll()
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
            sourceURL = nil; recipeSourceURL = nil; baselineRecipe = nil; savedRecipe = nil; namedSnapshots = []; savedSnapshotDate = nil
            development = nil; renderedPreviewImages = nil; histogram = nil
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
        let recipe = snapshotSession.recipeForSaving(currentRecipe)
        savingRecipe = true
        defer { savingRecipe = false }
        do {
            #if os(macOS)
            guard SidecarFolderAccess.shared.requestIfNeeded(for: sourceURL) else { return }
            #endif
            let saved = try RecipeStore.shared.saveSynchronously(recipe, for: sourceURL)
            savedRecipe = saved
            savedSnapshotDate = Date()
            baselineRecipe = saved
            var session = snapshotSession
            session.didSave(saved)
            snapshotSession = session
            restoreHistory(saved)
            editHistory.seed(saved)
            pendingEdits.remove(sourceURL)
            tutorial.record(.save)
        } catch { errorMessage = String(localized: "Could not save edits: \(error.localizedDescription) If folder access is denied, open the containing folder in the file browser and try again.") }
    }

    private var histogramView: some View {
        LinearHistogram(development: development, histogram: histogram,
                        histogramError: histogramError, binCount: $histogramBins,
                        mapping: $mapping, sdrSource: previewImages?.sdr,
                        revision: previewRevision, colorSpace: colorSpace, hdrPreview: hdrPreview,
                        comparingOriginal: $comparingOriginalMouse,
                        showingSDR: $displayMode.sdrHistogram,
                        hoverTransform: !displayMode.sdrHistogram && !cropping ? previewMapping.transform : nil,
                        onWhitePointEditingChanged: { editing in
                            adjustingWhitePoint = editing
                            toneLocatorImage = nil
                        })
    }

    private var tonePanel: some View {
    VStack(spacing: 0) {
        HStack {
            Text("Tone").font(.headline)
            Spacer()
            Button("Truncate") {
                editHistory.flush()
                mapping = ToneTruncation.applying(to: mapping, space: colorSpace)
                editHistory.observe(currentRecipe, name: String(localized: "Truncate"))
                editHistory.flush()
            }
            .disabled(resettingTone)
            .filmLock(.whitePoint).filmLock(.contrast).filmLock(.tone)
            .help("Move the white point to SDR level 254/255 and scale Contrast by the same ratio.")
            Button("Reset Tone", action: resetTone).disabled(resettingTone)
        }.padding(12)
        SlopeEditor(mapping: $mapping, sourceISO: development?.metadata.iso,
           rawExposure: development?.isRAW == true ? Double(rawSettings.values[.exposure] ?? 0) : 0,
           onToneChanged: { tutorial.record(.tone) },
           onContrastChanged: { tutorial.record(.contrast) },
           onISOAdjustment: { hdrPreview = false },
           onHDRGainAdjustment: { hdrPreview = mapping.hdrEnabled },
           onToneEditingChanged: { editing in
               adjustingTone = editing
               if !editing { toneLocatorImage = nil }
           },
           onISOEditingChanged: { editing in
               adjustingWhitePoint = editing
               toneLocatorImage = nil
           })
        if !mapping.color.monochrome || mapping.rawWhiteBalance != nil {
        Divider()
        VectorscopeView(source: development?.preview,
                        hoverSource: previewImages?.sdr,
                        hoverRevision: previewRevision,
                        revision: development?.id ?? previewRevision,
                        colorSpace: colorSpace, mapping: Binding(
                    get: { previewMapping },
                    set: { mapping.whiteBalance = $0.whiteBalance; mapping.rawWhiteBalance = $0.rawWhiteBalance }), pickingWhiteBalance: $pickingWhiteBalance,
                        resetRAWBalance: resetRAWWhiteBalanceAction,
                        convertWhiteBalance: convertWhiteBalanceAction, commitRAWBalance: commitRAWWhiteBalance)
        }
    }
    }

    private var resetRAWWhiteBalanceAction: (() -> Void)? {
        guard development?.isRAW == true else { return nil }
        return {
            guard let sourceURL else { return }
            do {
                mapping.rawWhiteBalance = try resetDefaults.mapping.rawWhiteBalance ?? RAWWhiteBalance.asShot(sourceURL)
                mapping.whiteBalance = resetDefaults.mapping.whiteBalance
                commitRAWWhiteBalance()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func maximizeRAWRange() {
        guard let development, development.isRAW, !loading, !maximizingRAWRange else { return }
        maximizingRAWRange = true
        let originalSettings = rawSettings
        let originalBalance = mapping.rawWhiteBalance
        let worker = RAWDeveloper(colorSpace: colorSpace, rawSettings: originalSettings, rawWhiteBalance: originalBalance)
        Task {
            defer { maximizingRAWRange = false }
            do {
                let settings = try await worker.maximumRAWRange(development.url)
                guard self.development?.id == development.id, !loading,
                      rawSettings == originalSettings, mapping.rawWhiteBalance == originalBalance else { return }
                rawSettings = settings
                load(development.url, resetEdits: false)
            } catch {
                if self.development?.id == development.id { errorMessage = error.localizedDescription }
            }
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
        guard development != nil, !loading, !mapping.blackAndWhite.isEnabled, !mapping.color.monochrome else { return nil }
        return { togglePicker($0) }
    }

    private func togglePicker(_ tool: EditorPickerTool) {
        guard development != nil, !loading, !mapping.blackAndWhite.isEnabled, !mapping.color.monochrome else { return }
        if panel != .tone {
            pendingPicker = tool
            panel = .tone
            return
        }
        pickingWhiteBalance.toggle()
    }

    private var leftPanelPicker: some View {
        #if os(macOS)
        BrowserPanelPicker(selection: showingFileBrowser ? (showingLibrary ? 1 : 0) : nil) {
            toggleLeftPanel(library: $0 == 1)
        }.fixedSize()
        #else
        ControlGroup {
            Button("Folder") { toggleLeftPanel(library: false) }
            Button("Library") { toggleLeftPanel(library: true) }
        }
        #endif
    }

    private func navigateFile(_ direction: Int) -> Bool {
        guard !loading, !fileActionBusy, !cropping else { return false }
        browserModel.pendingURLs = Set(pendingEdits.entries.map(\.url))
        guard let url = browserModel.adjacentFile(to: sourceURL, direction: direction) else { return false }
        load(url, resetEdits: true)
        return true
    }

    private func toggleLeftPanel(library: Bool) {
        showingFileBrowser = !showingFileBrowser || showingLibrary != library
        showingLibrary = library
    }

    private var leftPanelShortcuts: some View {
        HStack {
            Button("Folder") { toggleLeftPanel(library: false) }
                .keyboardShortcut("f", modifiers: [])
            Button("Library") { toggleLeftPanel(library: true) }
                .keyboardShortcut("l", modifiers: [])
        }
    }

    private func startTutorial() {
        tutorialPresented = true
        tutorial.start()
        showingFileBrowser = true
        showingLibrary = false
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

    /// Browser status reflects committed gestures, not the live slider position.
    private var browserPendingURLs: Set<URL> {
        Set(pendingEdits.entries.map(\.url))
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
                if action == .pasteEdit {
                    pastedSettings = try SettingsClipboard.read()
                    if url.standardizedFileURL == recipeSourceURL?.standardizedFileURL {
                        browserPaste = nil
                    } else {
                        browserPaste = try await BrowserRecipeTarget.load(url, override: pendingEdits.entry(for: url)?.recipe)
                    }
                    showingPasteSettings = true
                    return
                }
                let target: BrowserFileDevelopment
                if action != .export, let development,
                   development.url.standardizedFileURL == url.standardizedFileURL {
                    target = BrowserFileDevelopment(development: development, recipe: currentRecipe, worker: developer, savedRecipe: savedRecipe)
                } else {
                    // Export deliberately uses disk settings or automatic defaults.
                    let draft = action == .export ? nil : pendingEdits.entry(for: url)?.recipe
                    target = try await BrowserFileDevelopment.load(url, override: draft, bins: histogramBins, film: lockedFilm)
                }
                switch action {
                case .copyEdit:
                    try SettingsClipboard.copy(target.recipe, reference: target.development.whitePoint, source: target.development.url)
                case .pasteEdit: break
                case .export:
                    beginExportOptions(target)
                case .deleteEdit, .showInFinder: break
                }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func applyPastedSettings(_ selection: SettingsPasteSelection, target: BrowserRecipeTarget?) {
        guard let pastedSettings, !loading else { return }
        commitHistory()
        if let target, target.url.standardizedFileURL != recipeSourceURL?.standardizedFileURL {
            let url = target.url
            let draft = pendingEdits.entry(for: url)
            let destination = draft?.recipe ?? target.recipe
            var updated = selection.applying(pastedSettings.mapping, to: destination.mapping)
            if selection.contains(.rawWhiteBalance), target.isRAW, let wb = pastedSettings.mapping.rawWhiteBalance {
                updated.rawWhiteBalance = wb
            }
            var updatedRecipe = DevelopmentRecipe(colorSpace: destination.colorSpace, mapping: updated,
                rawSettings: target.isRAW ? selection.applyingRAW(pastedSettings.rawSettings, to: destination.rawSettings) : destination.rawSettings,
                snapshots: destination.snapshots)
            let session = SnapshotSession(selected: "unsaved", draft: SnapshotEdit(updatedRecipe), draftModifiedAt: Date())
            updatedRecipe.draftSnapshot = session.persistedDraft
            editHistory.record(url, from: destination, to: updatedRecipe, name: String(localized: "Paste Edits"))
            pendingEdits.remember(url: url, recipe: updatedRecipe,
                baseline: draft?.baseline ?? target.recipe, saved: draft?.savedRecipe ?? target.savedRecipe, session: session)
        } else {
            guard development != nil else { return }
                    comparingColor = false
            comparingEffects = false
            pickingWhiteBalance = false
            let previousRAWSettings = rawSettings
            if development?.isRAW == true,
               let updated = selection.applyingRAW(pastedSettings.rawSettings, to: rawSettings) {
                rawSettings = updated
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
                    let target = try await BrowserRecipeTarget.load(url,
                        override: pendingEdits.entry(for: url)?.recipe)
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

    private func finishFileExport(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            if exportedSourceURL?.standardizedFileURL == recipeSourceURL?.standardizedFileURL { tutorial.record(.export) }
        case .failure(let error): errorMessage = error.localizedDescription
        }
        exportDocument = nil
    }

    /// Match single export: the active snapshot wins over any older pending entry.
    private var batchRecipeOverrides: [URL: DevelopmentRecipe] {
        var recipes = Dictionary(uniqueKeysWithValues: pendingEdits.entries.map { ($0.url, $0.recipe) })
        if let url = recipeSourceURL, development != nil, !loading {
            recipes[url.standardizedFileURL] = currentRecipe
        }
        return recipes
    }

    private func beginExportOptions(_ target: BrowserFileDevelopment? = nil, variation: Bool = false) {
        variationExportMode = variation
        guard let source = target?.development ?? development else { return }
        let original = target?.recipe ?? currentRecipe
        exportSession = (source, lockedFilm?.applying(to: original) ?? original)
        #if os(macOS)
        // Capture the editor before the options sheet takes focus. Attaching the
        // save panel to that closing sheet would dismiss the save panel with it.
        var window = NSApp.keyWindow ?? NSApp.mainWindow
        while let parent = window?.sheetParent { window = parent }
        exportPresentationWindow = window
        #endif
        showingExportOptions = true
    }

    private func prepareExport(development: RAWDevelopment, recipe: DevelopmentRecipe, worker: RAWDeveloper) {
        let variation = variationExportMode ? VariationExport(grid: variationGrid, strength: UserDefaults.standard.object(forKey: "dyeRandomStrength") as? Double ?? 1) : nil
        let plan = ExportPlan(items: [PreparedExportItem(source: development.url, recipe: recipe)], settings: exportSettings, variation: variation)
        #if os(macOS)
        // The options sheet closes before the save panel opens. No live editor
        // state is read after this immutable plan has been created.
        pendingSingleExport = (plan, worker)
        #else
        exportedSourceURL = development.url
        exporting = true
        exportContentType = plan.settings.format.type
        exportName = development.url.deletingPathExtension().lastPathComponent + "." + plan.settings.format.fileExtension
        Task {
            defer { exporting = false }
            do {
                await worker.useLUTConfiguration(plan.items.first?.lutConfiguration)
                let data: Data
                if let variation = plan.variation {
                    data = try await worker.variationExport(development.url, mapping: recipe.mapping, settings: plan.settings, variation: variation)
                } else {
                    data = try await worker.cachedExport(development.url, mapping: recipe.mapping, settings: plan.settings)
                }
                exportDocument = HEIFDocument(data: data)
                showingSave = true
            } catch { errorMessage = error.localizedDescription }
        }
        #endif
    }

    #if os(macOS)
    private func chooseExportDestination(_ plan: ExportPlan, worker: RAWDeveloper, window: NSWindow?) {
        guard let item = plan.items.first else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [plan.settings.format.type]
        panel.nameFieldStringValue = item.source.deletingPathExtension().lastPathComponent + (plan.variation == nil ? "" : "-variations") + "." + plan.settings.format.fileExtension
        panel.canCreateDirectories = true
        let complete: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            exportQueue.enqueue(plan, destination: .file(url), cachedWorker: worker) {
                if item.source.standardizedFileURL == recipeSourceURL?.standardizedFileURL { tutorial.record(.export) }
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: complete) }
        else { panel.begin(completionHandler: complete) }
    }
    #endif

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
    let hdrPreview: Bool
    @Binding var comparingOriginal: Bool
    @Binding var showingSDR: Bool
    let hoverTransform: TransformSettings?
    var onWhitePointEditingChanged: (Bool) -> Void = { _ in }
    @State private var sdrHistogram: HistogramData?
    @State private var sdrError: String?
    @State private var sdrWorker: GPUHistogram?
    @State private var workerSpace: ProcessingColorSpace?
    @State private var draggingInputMaximum: Double?
    @State private var zoomHistogram: HistogramData?
    @State private var zoomWorker: GPUHistogram?
    @State private var zoomSpace: ProcessingColorSpace?
    @State private var completedZoomRequest: HistogramZoomRequest?
    private var inputMaximum: Double {
        draggingInputMaximum ?? HistogramInputRange.maximum(white: mapping.white, hdr: hdrPreview, encoded: showingSDR)
    }
    private var zoomRequest: HistogramZoomRequest {
        HistogramZoomRequest(sourceID: development?.id, bins: binCount, upper: inputMaximum, space: colorSpace)
    }
    private var usingZoomHistogram: Bool {
        !showingSDR && inputMaximum < 1 && completedZoomRequest == zoomRequest
    }
    private var displayedHistogram: HistogramData? {
        showingSDR ? sdrHistogram : usingZoomHistogram ? zoomHistogram : histogram
    }
    private var histogramMaximum: Double { usingZoomHistogram ? inputMaximum : 1 }

    private let colors: [Color] = [.red, .green, .blue]

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button(showingSDR ? "SDR RGB" : "Linear RGB") { showingSDR.toggle() }
                    .fontWeight(.medium)
                    .help("Toggle the linear source histogram and the developed SDR preview histogram. Black and white points can only be adjusted in Linear RGB.")
                Spacer()
                HoldCompareButton(comparing: $comparingOriginal, title: "Original")
                    .disabled(development == nil)
                    .help("Hold to preview Original in SDR with default tone settings and the current transform. Hold C for the same preview.")
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
                let visibleCount = max(1, min(count, Int(ceil(Double(count) * inputMaximum / histogramMaximum))))
                let scalingCounts = showingSDR
                    ? channels.flatMap { Array($0[3...252]) }
                    : channels.flatMap { Array($0.prefix(visibleCount)) }
                let peak = max(1, scalingCounts.max() ?? 1)
                let logPeak = log1p(Double(peak))
                context.blendMode = .plusLighter
                for channel in 0..<3 {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: size.height))
                    for index in 0..<visibleCount {
                        let x0 = CGFloat(index) / CGFloat(count) * size.width * histogramMaximum / inputMaximum
                        let x1 = CGFloat(index + 1) / CGFloat(count) * size.width * histogramMaximum / inputMaximum
                        let value = Double(channels[channel][index])
                        let height = showingSDR ? min(1, value / Double(peak)) : log1p(value) / logPeak
                        let y = size.height * (1 - CGFloat(height))
                        path.addLine(to: CGPoint(x: x0, y: y))
                        path.addLine(to: CGPoint(x: x1, y: y))
                    }
                    path.addLine(to: CGPoint(x: size.width, y: size.height))
                    path.closeSubpath()
                    context.fill(path, with: .color((mapping.color.monochrome ? Color.white : colors[channel]).opacity(0.45)))
                    context.stroke(path, with: .color((mapping.color.monochrome ? Color.white : colors[channel]).opacity(0.85)), lineWidth: 0.75)
                }
            }
            .clipped()
            .overlay {
                if !showingSDR { HistogramToneCurve(mapping: mapping, hdrPreview: hdrPreview, inputMaximum: inputMaximum).allowsHitTesting(false) }
            }
            .overlay {
                HoverPixelOverlay(source: showingSDR ? sdrSource : development?.preview,
                    revision: showingSDR ? revision : development?.id, space: colorSpace,
                    encoded: showingSDR, transform: hoverTransform) { context, size, rgb in
                    let weights = colorSpace.luminance
                    let value = rgb.x * weights.x + rgb.y * weights.y + rgb.z * weights.z
                    let x = min(size.width - 1, max(1, min(1, max(0, value / inputMaximum)) * size.width))
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: 0))
                    line.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(line, with: .color(.black.opacity(0.9)), lineWidth: 3)
                    context.stroke(line, with: .color(.white),
                                   style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    let label = Text("Y" + (value < 0 ? "‹" : value > inputMaximum ? "›" : ""))
                        .font(.caption2.bold())
                    let point = CGPoint(x: min(size.width - 12, max(12, x)), y: 9)
                    context.draw(label.foregroundStyle(.black), at: CGPoint(x: point.x + 1, y: point.y + 1))
                    context.draw(label.foregroundStyle(.white), at: point)
                }
                .allowsHitTesting(false)
            }
            .overlay {
                if !showingSDR { HistogramPoints(mapping: $mapping, inputMaximum: inputMaximum, onWhitePointEditingChanged: { editing in
                    // Freeze the axis during a drag so zoom cannot feed back into picking.
                    if editing { draggingInputMaximum = inputMaximum }
                    else { draggingInputMaximum = nil }
                    onWhitePointEditingChanged(editing)
                }).filmLock(.whitePoint) }
            }
            .frame(height: 190)
            .onGeometryChange(for: Int.self) { geometry in
                max(1, Int(geometry.size.width.rounded(.down)))
            } action: { binCount = $0 }
            HStack {
                ForEach(0...4, id: \.self) { tick in
                    if showingSDR { Text("\(Int((Double(tick) * 255 / 4).rounded()))") }
                    else { Text(Double(tick) / 4 * inputMaximum, format: .number.precision(.fractionLength(inputMaximum < 0.01 ? 4 : inputMaximum < 0.1 ? 3 : 2))) }
                    if tick < 4 { Spacer() }
                }
            }
            .foregroundStyle(.secondary)
            if let error = showingSDR ? sdrError : histogramError {
                Text("Histogram unavailable: \(error)").foregroundStyle(.secondary)
            } else if displayedHistogram == nil, development != nil {
                ProgressView().controlSize(.small)
            }
        }
        .font(.caption.monospacedDigit())
        .padding(12)
        .background(.bar)
        .task(id: zoomRequest) {
            let request = zoomRequest
            guard request.upper < 1, !showingSDR, let source = development?.preview, let id = request.sourceID else { return }
            do {
                if zoomWorker == nil || zoomSpace != colorSpace {
                    zoomWorker = try GPUHistogram(colorSpace: colorSpace)
                    zoomSpace = colorSpace
                }
                let result = try await zoomWorker!.calculate(image: CIImage(cgImage: source), sourceID: id,
                                                            bins: request.bins, upperInput: request.upper)
                try Task.checkCancellation()
                zoomHistogram = result
                completedZoomRequest = request
            } catch { /* Keep the existing source histogram if the zoom pass is unavailable. */ }
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
    var lutRevision: Int = 0
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




private struct HistogramZoomRequest: Equatable {
    let sourceID: UUID?
    let bins: Int
    let upper: Double
    let space: ProcessingColorSpace
}

private struct FullSourceRequest: Equatable {
    let source: UUID?
    let previewReady: Bool
    let loading: Bool
}
