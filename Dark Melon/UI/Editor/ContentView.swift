import SwiftUI
import Combine
import CoreImage
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.displayScale) private var displayScale
    @State private var comparison = ImageComparisonSession()
    @State private var comparisonFiles: [URL] = []
    @State private var comparisonSnapshots: [String] = []
    @State private var comparisonReload = 0
    private var comparingMultiple: Bool { comparisonFiles.count > 1 || comparisonSnapshots.count > 1 }
    private var comparingSnapshots: Bool { comparisonSnapshots.count > 1 }
    private var comparisonInputs: [ComparisonInput] {
        if comparingSnapshots, let url = recipeSourceURL {
            return comparisonSnapshots.compactMap { key in
                let recipe: DevelopmentRecipe?
                let title: String
                if key == "saved" { recipe = savedRecipe ?? baselineRecipe; title = String(localized: "Saved Edit") }
                else if key == "unsaved" { recipe = snapshotSession.draft?.recipe; title = String(localized: "Unsaved Edit") }
                else { let snapshot = namedSnapshots.first { $0.id.uuidString == key }; recipe = snapshot?.edit.recipe; title = snapshot?.name ?? key }
                guard let recipe else { return nil }
                return ComparisonInput(id: key, url: url, title: title, recipe: recipe)
            }
        }
        let overrides = batchRecipeOverrides
        return comparisonFiles.map { url in
            ComparisonInput(id: url.absoluteString, url: url, title: url.lastPathComponent,
                recipe: overrides[url.standardizedFileURL])
        }
    }
    private struct ComparisonRequest: Equatable {
        var inputs: [ComparisonInput]
        var revision: Int
        var listing: UUID
        var canvas: CGSize
    }
    @State private var turbo = TurboMode.shared
    @AppStorage("autoTurbo") private var autoTurbo = "never"
    @State private var previewCanvas = CGSize(width: 2560, height: 2560)
    @State private var overviewScreenPixels: CGSize?
    private var overviewCanvas: CGSize { overviewScreenPixels ?? previewCanvas }
    private var overviewRefinementReady: Bool {
        guard let source = previewDevelopment, source.fullResolutionReady else { return false }
        let scale = PreviewResolution.overviewScale(source: source.linearSource.extent.size, canvas: overviewCanvas)
        return source.linearSource.extent.width * scale > CGFloat(source.preview.width) + 1
            || source.linearSource.extent.height * scale > CGFloat(source.preview.height) + 1
    }
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
        guard !comparingMultiple else { return }
        do {
            if let sourceURL {
                try SettingsClipboard.copy(currentRecipe, reference: development?.whitePoint, source: sourceURL)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func pasteDevelopmentSettings() {
        guard !comparingMultiple else { return }
        do {
            pastedSettings = try SettingsClipboard.read()
            browserPaste = nil
            showingPasteSettings = true
        } catch { errorMessage = error.localizedDescription }
    }

    private var activePresetPreview: PresetPreview? {
        presetPreview?.id == confirmingPreset?.id ? presetPreview : nil
    }
    @State private var doubleSource = 0
    @State private var isolatedRAWDevelopment: RAWDevelopment?
    private var isolatingRAW: Bool { panel == .raw && mapping.doubleExposure != nil }
    private var activeRAWURL: URL? {
        guard let sourceURL else { return nil }
        return mapping.doubleExposure?.urls(relativeTo: sourceURL)[doubleSource] ?? sourceURL
    }
    private var activeRAWSettings: Binding<RAWSettings> {
        Binding(get: {
            var value = doubleSource == 1 ? (mapping.doubleExposure?.secondRAW ?? rawSettings).resolved(using: isolatedRAWDevelopment?.rawDefaults ?? development?.rawDefaults ?? RAWSettings()) : rawSettings
            value.decoderMode = rawSettings.decoderMode
            return value
        }, set: { value in
            if doubleSource == 1, mapping.doubleExposure != nil {
                var local = value; local.decoderMode = rawSettings.decoderMode
                mapping.doubleExposure?.secondRAW = local
                rawSettings.decoderMode = value.decoderMode
            } else { rawSettings = value }
        })
    }
    private var activeRAWBalance: Binding<RAWWhiteBalance?> {
        Binding(get: { doubleSource == 1 ? mapping.doubleExposure?.secondBalance ?? mapping.rawWhiteBalance : mapping.rawWhiteBalance }, set: {
            if doubleSource == 1, mapping.doubleExposure != nil { mapping.doubleExposure?.secondBalance = $0 }
            else { mapping.rawWhiteBalance = $0 }
        })
    }
    private var previewDevelopment: RAWDevelopment? {
        if isolatingRAW { return isolatedRAWDevelopment }
        if let activePresetPreview, !presetShowingBefore { return activePresetPreview.development }
        return development
    }
    @State private var browserPaste: BrowserRecipeTarget?
    @State private var exportSession: ImageExportSession?
    @State private var fileActionBusy = false
    @State private var deleteEditURLs: [URL] = []
    @State private var pasteEditURLs: [URL] = []
    @State private var exportedSourceURL: URL?
    @State private var resettingTone = false
    @State private var browserModel = ImageBrowserModel(remembersFolder: true)
    @State private var showingFileBrowser = true
    @AppStorage("leftPanel.library") private var showingLibrary = false
    #if os(macOS)
    @State private var showingBatchExport = false
    @State private var exportQueue = ExportQueue.shared
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
    @State private var glassPanelVisible = true
    @State private var panel = EditorPanel.tone
    @State private var comparingOriginal = false
    @State private var comparingChromaRange = false
    @State private var comparingColor = false
    @State private var comparingCrossProcessing = false
    @State private var comparingEffects = false
    @State private var colorSpace = ProcessingColorSpace.sRGB
    @State private var sourceURL: URL?
    @State private var developer = RAWDeveloper()
    @State private var histogramWorker = RAWDeveloper()
    @State private var histogramBins = 1
    @State private var histogram: HistogramData?
    @State private var histogramError: String?
    @State private var exportSettings = HEIFSettings.restored()
    #if DEBUG && os(macOS)
    @State private var lutVisualizer = LUTVisualizerWindow()
    private var lutVisualizerInput: LUTVisualizerInput { LUTVisualizerInput(mapping: mapping, colorSpace: colorSpace) }
    #endif
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
    @AppStorage("preview.prefersHDR") private var prefersHDR = true
    @State private var prefersSDRHistogram = false
    private var canPreviewHDR: Bool {
        development != nil && !loading && mapping.hdrEnabled && previewImages?.hasHDROutput == true
    }
    private var hdrPreview: Bool {
        get { !isolatingRAW && !comparingOriginal && prefersHDR && canPreviewHDR }
        nonmutating set {
            guard canPreviewHDR else { return }
            prefersHDR = newValue
            if newValue { prefersSDRHistogram = false }
        }
    }
    private var showingSDRHistogram: Bool { prefersSDRHistogram && !hdrPreview }
    private var sdrHistogramBinding: Binding<Bool> {
        Binding(get: { showingSDRHistogram }, set: {
            prefersSDRHistogram = $0
            if $0 && canPreviewHDR { prefersHDR = false }
        })
    }
    @State private var measuredPreviewSourceID: UUID?
    @State private var openingImage: CGImage?
    @State private var openingID = UUID()
    @State private var openingTask: Task<Void, Never>?
    @State private var quickOpeningTask: Task<Void, Never>?
    @State private var renderedPreviewImages: PreviewImages?
    private var previewImages: PreviewImages? {
        if let activePresetPreview { return presetShowingBefore ? activePresetPreview.before : activePresetPreview.after }
        return renderedPreviewImages
    }
    @State private var dustEditor = DustEditor()
    @State private var dustTask: Task<Void, Never>?
    @State private var dustGeneration = UUID()
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
        return EditorUndoActions(canUndo: !comparingMultiple && !loading && editHistory.canUndo,
            canRedo: !comparingMultiple && !loading && editHistory.canRedo,
            undoTitle: editHistory.undoTitle, redoTitle: editHistory.redoTitle,
            undo: { if !comparingMultiple { commitHistory(); editHistory.undo() } },
            redo: { if !comparingMultiple { editHistory.redo() } })
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
        let restoredRAW = recipe.rawSettings ?? (development?.isRAW == false ? RAWSettings() : rawSettings)
        let reload = colorSpace != recipe.colorSpace || rawSettings != restoredRAW
            || mapping.rawWhiteBalance != recipe.mapping.rawWhiteBalance || mapping.doubleExposure != recipe.mapping.doubleExposure
        cropping = false
        adjustingTone = false; adjustingWhitePoint = false; pickingWhiteBalance = false
        comparingChromaRange = false; comparingColor = false; comparingEffects = false; comparingCrossProcessing = false
        colorSpace = recipe.colorSpace
        mapping = recipe.mapping
        rawSettings = restoredRAW
        cropPolygon = mapping.transform?.points ?? [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
        if reload, let sourceURL { load(sourceURL, resetEdits: false) }
        rememberCurrentEdits()
    }

    @State private var asShotBalance: RAWWhiteBalance?

    @State private var defaultsCache = EditorDefaultsCache()
    private var resetDefaults: DevelopmentRecipe {
        defaultsCache.resolve(space: colorSpace, isRAW: development?.isRAW == true,
            headroom: development?.sourceHeadroom ?? 1, raw: development?.rawDefaults,
            balance: asShotBalance, preset: EditLibrary.shared.rawDefaultPreset,
            sourceSize: development.map { CGSize(width: $0.width, height: $0.height) })
    }

    private var comparing: Bool { comparingOriginal || comparingChromaRange || comparingColor || comparingCrossProcessing || comparingEffects }
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
        result.dustSpots = mapping.dustSpots
        return result
    }

    private var detailRequest: DetailPreviewRequest {
        let counterpart: ToneMapping? = confirmingPreset != nil ? nil : comparing ? mapping
            : ([.color, .effects].contains(panel) ? comparisonMapping(panel) : originalMapping)
        return DetailPreviewRequest(sourceID: previewDevelopment?.id, mapping: previewMapping,
            counterpart: counterpart, comparing: comparing || confirmingPreset != nil, hdr: hdrPreview,
            region: previewRegion, enabled: !comparingMultiple && previewDevelopment?.dustSpots == (previewMapping.dustSpots ?? []) && previewDevelopment?.fullResolutionReady == true && !loading && !cropping && !adjustingTone && !adjustingWhitePoint
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
        return DevelopmentRecipe(colorSpace: colorSpace, mapping: savedMapping, rawSettings: recipeRAWSettings, snapshots: namedSnapshots, draftSnapshot: snapshotSession.persistedDraft)
    }

    private var recipeRAWSettings: RAWSettings? {
        if development?.isRAW == true || mapping.rawWhiteBalance != nil { return rawSettings }
        guard rawSettings.orientation != SourceOrientation() else { return nil }
        // Non-RAW files still need their source geometry saved, without decoder adjustments.
        var geometry = RAWSettings()
        geometry.orientation = rawSettings.orientation
        return geometry
    }

    private var draftTransform: TransformSettings? {
        let result = TransformSettings(points: cropPolygon, ratioPosition: cropRatioPosition,
                                       rotation: cropTransform.rotation, horizontal: cropTransform.horizontal, vertical: cropTransform.vertical)
        return result.isValid ? result : nil
    }

    private func commitTransform() {
        guard cropping else { return }
        mapping.transform = draftTransform
        cropping = false
    }

    private func beginTransform() {
        guard !cropping, !loading, development != nil,
              lockedFilm?.selection.contains(.transform) != true else { return }

        #if os(macOS)
        previewViewport.zoom = 1
        previewViewport.offset = .zero
        #endif
        if let saved = mapping.transform {
            cropRatioPosition = saved.ratioPosition
            cropTransform = CropTransform(rotation: saved.rotation, horizontal: saved.horizontal, vertical: saved.vertical)
            cropPolygon = saved.points
        } else if let development {
            cropRatioPosition = CropGeometry.position(for: Double(development.width) / Double(max(1, development.height)))
            cropTransform = CropTransform()
            cropPolygon = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
        }
        cropping = true
    }

    private func toggleTransform() {
        if cropping { commitTransform() } else { beginTransform() }
    }

    private var transformOrientation: Binding<SourceOrientation> {
        Binding(get: { rawSettings.orientation }, set: changeTransformOrientation)
    }

    private func changeTransformOrientation(_ orientation: SourceOrientation) {
        let previous = rawSettings.orientation
        guard orientation != previous else { return }
        commitHistory()
        let before = currentRecipe
        commitTransform()
        mapping.transform = mapping.transform?.reoriented(from: previous, to: orientation)
        rawSettings.orientation = orientation
        cropPolygon = mapping.transform?.points ?? [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
        cropRatioPosition = mapping.transform?.ratioPosition ?? 5
        cropTransform = CropTransform(rotation: mapping.transform?.rotation ?? 0,
            horizontal: mapping.transform?.horizontal ?? 0, vertical: mapping.transform?.vertical ?? 0)
        previewDetails.removeAll()
        previewRegion = nil
        #if os(macOS)
        previewViewport.zoom = 1
        previewViewport.offset = .zero
        #endif
        recordRecipeChange(from: before, to: currentRecipe)
        snapshotAppliedRecipe = currentRecipe
        rememberCurrentEdits()
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

    private func configureDustEditor() {
        dustEditor.spots = mapping.dustSpots ?? []
        dustEditor.geometry = development?.dustGeometry ?? DustGeometry()
        dustEditor.sourceSize = CGSize(width: development?.width ?? 1, height: development?.height ?? 1)
        dustEditor.transform = mapping.transform
        dustEditor.change = { spots in mapping.dustSpots = spots.isEmpty ? nil : spots }
        dustEditor.fit = { spot in sampleDust(spot, fit: true) }
        dustEditor.resample = { spot in sampleDust(spot, fit: false) }
        dustEditor.redraw()
    }

    private func sampleDust(_ spot: DustSpot, fit: Bool) {
        guard let development else { return }
        dustTask?.cancel()
        let revision = UUID(); dustGeneration = revision
        let worker = developer, originalSpots = mapping.dustSpots
        let spots = originalSpots ?? []
        dustEditor.busy = true; dustEditor.message = nil
        dustTask = Task {
            defer { if dustGeneration == revision { dustEditor.busy = false } }
            do {
                // Fit full-resolution data, even while the visible overview is lightweight.
                let source = development
                let profile = try await worker.dustProfile(source, spot: spot, spots: spots)
                try Task.checkCancellation()
                guard dustGeneration == revision, self.development?.id == development.id,
                      mapping.dustSpots == originalSpots else { return }
                if fit {
                    let nativeSize = source.dustGeometry.nativeSize(source.linearSource.extent.size)
                    let fitted = try await Task.detached(priority: .userInitiated) { try DustFitter.fit(profile, spot: spot, nativeSize: nativeSize) }.value
                    try Task.checkCancellation()
                    guard dustGeneration == revision, mapping.dustSpots == originalSpots else { return }
                    // Re-sample after recentering so the graph and correction share coordinates.
                    let centered = try await worker.dustProfile(source, spot: fitted.0, spots: spots)
                    try Task.checkCancellation()
                    guard dustGeneration == revision, mapping.dustSpots == originalSpots else { return }
                    dustEditor.update(fitted.0)
                    var graph = centered
                    let background = fitted.1.background
                    let edge = min(nativeSize.width, nativeSize.height)
                    let shift = ((fitted.0.center.x-spot.center.x)*nativeSize.width*cos(spot.angle)
                        + (fitted.0.center.y-spot.center.y)*nativeSize.height*sin(spot.angle))/edge
                    if let first = background.first, let last = background.last {
                        let delta = (last-first)*shift/spot.length
                        graph.background = background.map { $0 + delta }
                    }
                    dustEditor.profile = graph
                    commitHistory()
                } else {
                    var graph = profile
                    let n = graph.values.count, count = max(1, n/5)
                    let left = graph.values.prefix(count).reduce(0,+)/Double(count)
                    let right = graph.values.suffix(count).reduce(0,+)/Double(count)
                    graph.background = (0..<n).map { left + (right-left)*(Double($0)/Double(max(1,n-1))-0.1)/0.8 }
                    dustEditor.profile = graph
                }
            } catch is CancellationError {} catch {
                if dustGeneration == revision, mapping.dustSpots == originalSpots {
                    dustEditor.message = error.localizedDescription
                    // Keep a failed new fit as an editable, zero-strength spot.
                    if !spots.contains(where: { $0.id == spot.id }) {
                        mapping.dustSpots = dustEditor.spots
                        commitHistory()
                    }
                }
            }
        }
    }

    private func originalPreviewPoint(_ point: CGPoint) -> CGPoint {
        guard !cropping, let transform = previewMapping.transform else { return point }
        let source = transform.sourcePoint(CGPoint(x: point.x, y: 1 - point.y))
        return CGPoint(x: source.x, y: 1 - source.y)
    }

    private func comparisonMapping(_ panel: EditorPanel) -> ToneMapping {
        var result = mapping
        if panel == .color { result = result.comparingColor(chromaRange: true, color: true) }
        if panel == .effects { result = result.comparingEffects(crossProcessing: false, effects: true) }
        return result
    }

    private var previewMapping: ToneMapping {
        if isolatingRAW { return ToneMapping.fresh(isRAW: false, sourceHeadroom: 1) }
        if let activePresetPreview { return presetShowingBefore ? mapping : activePresetPreview.recipe.mapping }
        if comparingOriginal { return originalMapping }
        let base = mapping.comparingColor(chromaRange: comparingChromaRange, color: comparingColor)
        return base.comparingEffects(crossProcessing: comparingCrossProcessing, effects: comparingEffects)
    }

    private var libraryPanel: some View {
        GeometryReader { geometry in
            VStack(spacing: EditorSectionLayout.spacing) {
                EditLibraryView(current: comparingMultiple || development == nil || loading ? nil : currentRecipe, selectedLUT: $mapping.lutID, filename: filename) { name, recipe, selection in
                    commitHistory()
                    confirmingPreset = PresetApplication(name: name, recipe: recipe, selection: selection)
                }.disabled(comparingMultiple)
                .frame(height: max(0, (geometry.size.height - EditorSectionLayout.spacing) / 2))
                .clipShape(.rect(cornerRadius: EditorSectionLayout.sectionCornerRadius))
                .modifier(ShellSection())
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
                EditSnapshotsView(saved: savedRecipe != nil, savedAt: savedSnapshotDate, draftAt: snapshotSession.draftModifiedAt, draft: snapshotSession.draft != nil,
                    snapshots: namedSnapshots, selected: snapshotSession.selected,
                    select: selectSnapshot, create: { if !comparingMultiple { createSnapshot($0) } }, update: { if !comparingMultiple { updateSnapshot($0) } }, delete: { if !comparingMultiple { deleteSnapshot($0) } }, discardDraft: { if !comparingMultiple { discardSnapshotDraft() } },
                    comparisonSelection: { keys in comparisonFiles = []; comparisonSnapshots = keys }, comparisonKeys: comparisonSnapshots, openReference: openSnapshotReference, mutationsDisabled: comparingMultiple)
                    .disabled(development == nil || loading)
                    .frame(maxHeight: .infinity)
                    .clipShape(.rect(cornerRadius: EditorSectionLayout.sectionCornerRadius))
                    .modifier(ShellSection())
            }
        }
        .scrollContentBackground(.hidden)
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

    private var browserPanel: some View {
        Group {
            if showingLibrary {
                libraryPanel
            } else {
                ImageFileBrowser(selectedURL: sourceURL, open: { load($0, resetEdits: true) }, model: browserModel, comparisonSelection: { urls in comparisonSnapshots = []; comparisonFiles = urls }, comparisonURLs: comparisonFiles, changeDirectory: changeDirectory,
                                 fileAction: performFileAction, multipleFileAction: performMultipleFileAction, pendingURLs: browserPendingURLs)
                    .disabled(fileActionBusy)
                    .overlay { if fileActionBusy { ProgressView("Preparing…").padding().background(.regularMaterial) } }
                    .modifier(ShellSection())
            }
        }
    }

    private var editorPreview: some View {
    VStack(spacing: 0) {
        ZStack {
            Color.clear
            if comparingMultiple {
                ImageComparisonView(session: comparison, hdr: prefersHDR)
            } else if let previewImages {
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
                                commitTransform: commitTransform,
                                cropInsets: CGSize(width: 24, height: 72),
                                panelEdgePadding: cropping ? 0 : 16,
                                dustEditor: panel == .transform && dustEditor.enabled && !cropping && lockedFilm?.selection.contains(.dustCorrection) != true ? dustEditor : nil,
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
                    .modifier(PreviewPanelOverflow())
                    .modifier(HDRScreenSaver())
                    .padding(cropping ? 0 : 16)
                #else
                if cropping {
                    MobileCropPreview(image: hdrPreview ? previewImages.fullHDR : previewImages.fullSDR,
                                      hdr: hdrPreview, ratio: CropGeometry.ratio(at: cropRatioPosition), transform: $cropTransform, savedTransform: previewMapping.transform, cropChanged: { cropPolygon = $0 },
                                      safeInsets: CGSize(width: 24, height: 72))
                        .onTapGesture(count: 2, perform: commitTransform)
                } else {
                Image(decorative: ((adjustingTone || adjustingWhitePoint) ? toneLocatorImage : nil) ?? (cropping ? (hdrPreview ? previewImages.fullHDR : previewImages.fullSDR) : (hdrPreview ? previewImages.hdr : previewImages.sdr)), scale: 1)
                    .allowedDynamicRange(hdrPreview ? .high : .standard)
                    .resizable()
                    .scaledToFit()
                    .overlay {
                        if panel == .transform, dustEditor.enabled, lockedFilm?.selection.contains(.dustCorrection) != true {
                            DustMobileOverlay(editor: dustEditor, aspect: Double(previewImages.sdr.width) / Double(previewImages.sdr.height))
                        }
                    }
                    .padding(16)
                }
                #endif
            } else if let openingImage {
                #if os(macOS)
                HDRImagePreview(sdrImage: openingImage, image: openingImage,
                    sourceSize: CGSize(width: openingImage.width, height: openingImage.height),
                    detail: nil, regionChanged: { _ in }, hdr: false, sourceID: openingID,
                    viewport: previewViewport, presentationOnly: true,
                    cropRatio: nil, cropTransform: .constant(CropTransform()),
                    savedTransform: nil, cropChanged: { _ in }, sampleTool: nil,
                    hover: { _ in }, sample: { _, _ in })
                    .modifier(PreviewPanelOverflow())
                    .padding(16)
                    .allowsHitTesting(false)
                #else
                Image(decorative: openingImage, scale: 1)
                    .resizable().scaledToFit().padding(16)
                    .allowsHitTesting(false)
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
            if !comparingMultiple && openingImage == nil && (loading || (development != nil && previewImages == nil)) {
                ProgressView("Loading image…")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(EmptyPreviewBackgroundMenu(enabled: previewImages == nil && openingImage == nil && !comparingMultiple))
        #if os(macOS)
        .background(OverviewDisplayProbe(pixels: $overviewScreenPixels).frame(width: 0, height: 0))
        #endif
        .onGeometryChange(for: CGSize.self) { proxy in
            // Quantize resize requests slightly, while covering Retina physical pixels.
            CGSize(width: max(64, ceil((proxy.size.width - 32) * displayScale / 64) * 64),
                   height: max(64, ceil((proxy.size.height - 32) * displayScale / 64) * 64))
        } action: { previewCanvas = $0 }
        #if DEBUG
        .overlay(alignment: .topLeading) {
            if !comparingMultiple, !loading, !cropping, confirmingPreset == nil,
               let development, measuredPreviewSourceID == development.id,
               let images = renderedPreviewImages {
                let fraction = Double(images.source.width) * Double(images.source.height)
                    / max(1, Double(development.width) * Double(development.height))
                HStack(spacing: 6) {
                    Text("GPU")
                    if let milliseconds = images.gpuMilliseconds {
                        Text(milliseconds, format: .number.precision(.fractionLength(1)))
                    } else {
                        Text("—")
                    }
                    Text("ms ·")
                    Text("Total")
                    Text(images.renderMilliseconds, format: .number.precision(.fractionLength(1)))
                    Text("ms ·")
                    Text(fraction, format: .percent.precision(.fractionLength(1)))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(6)
                .background(.black.opacity(0.55))
                .modifier(PreviewOverlayVisibility())
                .padding(12)
                .help("GPU measures pre-tone and final preview command execution. Total includes CPU setup and waiting. Both include SDR and available HDR renders, but exclude RAW decoding, scopes, and export encoding. Percentage is preview pixels divided by full-image pixels.")
            }
        }
        #endif
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
        if tutorial.active && !comparingMultiple {
            EditingTutorialGuide(tutorial: tutorial, imageReady: development != nil && !loading,
                                 hdrEnabled: mapping.hdrEnabled, advance: advanceTutorial,
                                 close: { tutorial.active = false })
        }
    }
    .frame(minWidth: 320)
    }

    private var editorControls: some View {
        InspectorScrollView {
            VStack(spacing: EditorSectionLayout.spacing) {
                if panel == .tone || panel == .raw {
                    histogramView
                }
                if panel == .color {
                    HueChromaScope(controls: $mapping.vertexWarp, monochrome: $mapping.color.monochrome, comparing: $comparingChromaRange, source: mapping.color.monochrome ? development?.preview : (hdrPreview ? previewImages?.hdr : previewImages?.sdr),
                        revision: mapping.color.monochrome ? development?.id ?? previewRevision : previewRevision, space: colorSpace,
                        headroom: previewMapping.hdrMax, hdr: hdrPreview,
                        hoverTransform: mapping.color.monochrome && !cropping ? previewMapping.transform : nil)

                }
                if panel == .transform {
                    TransformControls(cropping: cropping, orientation: transformOrientation,
                        orientationChanged: { if let sourceURL { load(sourceURL, resetEdits: false) } }, image: previewImages?.fullSDR,
                        polygon: cropping ? cropPolygon : mapping.transform?.points ?? cropPolygon,
                        resolution: (cropping ? draftTransform : mapping.transform)?.resolution(width: development?.width ?? 1, height: development?.height ?? 1)
                            ?? CGSize(width: development?.width ?? 1, height: development?.height ?? 1),
                        maximumResolution: (cropping ? draftTransform : mapping.transform)?.resolution(width: development?.width ?? 1, height: development?.height ?? 1, estimate: .maximum)
                            ?? CGSize(width: development?.width ?? 1, height: development?.height ?? 1),
                        toggle: toggleTransform,
                        resetPerspective: { if !cropping { toggleTransform() }; cropTransform.horizontal = resetDefaults.mapping.transform?.horizontal ?? 0; cropTransform.vertical = resetDefaults.mapping.transform?.vertical ?? 0 },
                        resetRotation: { if !cropping { toggleTransform() }; cropTransform.rotation = resetDefaults.mapping.transform?.rotation ?? 0 },
                        resetAll: resetTransform)
                    DustControls(editor: dustEditor, spots: $mapping.dustSpots, activate: {
                        if cropping { toggleTransform() }
                        pickingWhiteBalance = false
                        configureDustEditor()
                    }).filmLock(.dustCorrection)
                    ActiveLUTControls(mapping: $mapping).filmLock(.lut)
                } else if panel == .raw {
                    if let pair = mapping.doubleExposure {
                        RAWSourceSelector(selection: $doubleSource, first: pair.first, second: pair.second)
                    }
                    RAWControls(colorSpace: Binding(get: { colorSpace }, set: { selected in
                        guard selected != colorSpace else { return }
                        colorSpace = selected
                        if let sourceURL { load(sourceURL, resetEdits: false) }
                    }), colorSpaceDisabled: loading, halfTurnsOnly: mapping.doubleExposure != nil && doubleSource == 1,
                    showsOrientation: mapping.doubleExposure != nil && doubleSource == 1, settings: activeRAWSettings, isRAW: development?.isRAW == true, commit: {
                        if let sourceURL { load(sourceURL, resetEdits: false) }
                    }, reset: resetActiveRAW, maximizingRange: maximizingRAWRange, maxRange: maximizeRAWRange)
                    if mapping.doubleExposure != nil {
                        ColorTemperatureControls(whiteBalance: activeRAWBalance,
                            rgbGains: mapping.whiteBalance, monochrome: mapping.color.monochrome,
                            reset: resetRAWWhiteBalanceAction, convert: convertWhiteBalanceAction,
                            commit: commitRAWWhiteBalance, preset: applyRAWBalancePreset)
                            .disabled(mapping.blackAndWhite.isEnabled)
                            .padding(16).modifier(ShellSection())
                    }
                } else if panel == .color {
                    ColorControls(settings: $mapping.color, vertices: $mapping.vertexWarp, comparing: $comparingColor, monochrome: mapping.blackAndWhite.isEnabled || mapping.color.monochrome, hdrMax: mapping.hdrMax, colorSpace: colorSpace)
                } else if panel == .effects {
                    EffectsControls(badHDR: $mapping.badHDR, dyeMixers: $mapping.dyeMixers, randomizeDye: { strength in
                        let generation = DyeMixers.Generation(seed: UInt64.random(in: .min ... .max),
                            strength: UInt16((strength.clamped(to: 0...3) / 3 * 65535).rounded()))
                        if let candidate = DyeMixers.seeded(generation) {
                            mapping.dyeMixers = candidate
                        }
                    }, dyePurity: $mapping.dyePurity, channelContrast: $mapping.channelContrast, clarity: $mapping.clarity, radius: $mapping.clarityRadius, hdf: $mapping.hdf, hdfRadius: $mapping.hdfRadius, grain: $mapping.grain, halation: $mapping.halation, vignette: $mapping.vignette, hdrEnabled: mapping.hdrEnabled, monochrome: mapping.color.monochrome, comparing: $comparingEffects, comparingCrossProcessing: $comparingCrossProcessing)
                } else {
                    tonePanel
                }
            }
            .disabled(loading || development == nil)
        }
    }

    private var previewFolderPosition: String? {
        let files = browserModel.visibleFiles
        guard let sourceURL else { return nil }
        let current = sourceURL.standardizedFileURL
        guard let index = files.firstIndex(where: { $0.url == current }) else { return nil }
        return "\(index + 1) / \(files.count)"
    }

    private var editorLayout: some View {
        GlassEditorShell(browserVisible: showingFileBrowser,
            panelVisible: glassPanelVisible && !comparingMultiple,
            current: sourceURL, resolution: CGSize(width: development?.width ?? 0, height: development?.height ?? 0),
            fileSize: development?.metadata.fileSize,
            metadata: development?.metadata,
            folderPosition: previewFolderPosition,
            hdrEnabled: prefersHDR,
            showsBottomPill: !tutorial.active || comparingMultiple,
            comparisonMode: comparingMultiple ? $comparison.mode : nil,
            cropRatioPosition: cropping && !comparingMultiple ? $cropRatioPosition : nil,
            dismissBrowser: { showingFileBrowser = false }) {
                editorPreview
            } browser: {
                browserPanel
            } controls: {
                editorControls
            } pending: {
                PendingEditsControl(entries: pendingEdits.entries, current: sourceURL,
                    busy: loading || comparingMultiple,
                    open: { load($0, resetEdits: true) },
                    save: { do { try savePendingEdits() } catch { errorMessage = error.localizedDescription } },
                    ignore: { requestDiscard { if let sourceURL { load(sourceURL, resetEdits: true) } } })
            } leftToolbar: {
                HStack(spacing: 8) {
                    Button("Folder", systemImage: "photo.stack") { toggleLeftPanel(library: false) }
                        .buttonStyle(ShellPanelButtonStyle(selected: showingFileBrowser && !showingLibrary))
                        .accessibilityValue(showingFileBrowser && !showingLibrary ? "Open" : "Closed")
                        .help("Folder")
                    Button("Library", systemImage: "square.stack.3d.forward.dottedline") { toggleLeftPanel(library: true) }
                        .buttonStyle(ShellPanelButtonStyle(selected: showingFileBrowser && showingLibrary))
                        .accessibilityValue(showingFileBrowser && showingLibrary ? "Open" : "Closed")
                        .help("Library")
                }
                .labelStyle(.iconOnly)
                .focusable(false)
                .focusEffectDisabled()
            } toolbar: {
                HStack(spacing: 8) {
                    Button("Save", systemImage: "square.and.arrow.down") { saveRecipe() }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(comparingMultiple || development == nil || loading || savingRecipe)
                        .help("Save development settings beside the original image in an XMP sidecar")
                        .modifier(ShellToolbarItem())
                    Button("Export", systemImage: "square.and.arrow.up") { beginExportOptions() }
                        .keyboardShortcut("e", modifiers: [.command, .shift])
                        .disabled(comparingMultiple || development == nil || loading || exporting)
                        .modifier(ShellToolbarItem())
                    Toggle("Film Lock", systemImage: "lock", isOn: Binding(get: { lockedFilm != nil }, set: {
                        confirmingPreset = nil
                        if $0 { if !comparingMultiple { requestFilmLock() } }
                        else { lockedFilm = nil; comparisonReload += 1 }
                    })).toggleStyle(.button)
                        .disabled(comparingSnapshots || (comparingMultiple && lockedFilm == nil) || loading || (development == nil && lockedFilm == nil))
                        .help("Capture film settings and apply them as unsaved edits when opening another photo. Unlock to stop applying them.")
                        .modifier(ShellToolbarItem())
                    ShellToolbarDivider()
                    Toggle("HDR", isOn: Binding(get: { prefersHDR }, set: { enabled in
                        if comparingMultiple { prefersHDR = enabled } else { hdrPreview = enabled }
                        tutorial.previewToggled(hdr: enabled)
                    })).toggleStyle(.button)
                        .modifier(ShellToolbarItem())
                        .modifier(HDRButtonGlow(isOn: prefersHDR))
                        .keyboardShortcut("h", modifiers: [])
                        .disabled(comparingMultiple ? !comparison.panes.contains(where: { $0.images?.hasHDROutput == true }) : !canPreviewHDR)
                        .help("Toggle HDR or SDR display of the developed image")
                }.labelStyle(.iconOnly).buttonStyle(.plain)
            } rightToolbar: {
                HStack(spacing: 8) {
                    ForEach(EditorPanel.allCases) { item in
                        Button { selectPanel(item) } label: {
                            Image(systemName: item.shellSymbol)
                        }
                        .buttonStyle(ShellPanelButtonStyle(selected: panel == item && glassPanelVisible))
                        .focusable(false)
                        .focusEffectDisabled()
                        .accessibilityLabel(Text(LocalizedStringKey(item.rawValue)))
                        .accessibilityValue(panel == item && glassPanelVisible ? "Open" : "Closed")
                        .help(LocalizedStringKey(item.rawValue))
                    }
                }.labelStyle(.iconOnly).buttonStyle(.plain)
            }
    }

    private func selectPanel(_ selected: EditorPanel) {
        if panel == selected { glassPanelVisible.toggle() }
        else { panel = selected; glassPanelVisible = true }
    }

    private var editorLayoutWithShortcuts: some View {
        let copy: (() -> Void)? = comparingMultiple || development == nil || loading ? nil : { copyCurrentDevelopmentSettings() }
        let paste: (() -> Void)? = comparingMultiple || development == nil || loading ? nil : { pasteDevelopmentSettings() }
        return editorLayout
            .focusedSceneValue(\.copyDevelopmentSettings, copy)
            .focusedSceneValue(\.pasteDevelopmentSettings, paste)
    }

    private var editorScene: some View {
        AnyView(editorLayoutWithShortcuts)
            // Panel selection and sliders draw their own indicators. Suppress
            // automatic button focus decoration without disabling keyboard input.
            .focusEffectDisabled()
            .onChange(of: mapping.dustSpots) { _, _ in configureDustEditor() }
            .onChange(of: mapping.transform) { _, _ in configureDustEditor() }
            .onChange(of: development?.id) { _, _ in configureDustEditor() }
            .onChange(of: development?.url) { _, _ in
                dustTask?.cancel(); dustGeneration = UUID(); dustEditor.enabled = false
                dustEditor.selected = nil; dustEditor.profile = nil; configureDustEditor()
            }
            .onChange(of: panel) { _, _ in dustEditor.enabled = false }
            .onChange(of: cropping) { _, active in if active { dustEditor.enabled = false } }
            .onChange(of: pickingWhiteBalance) { _, active in if active { dustEditor.enabled = false } }
            .onChange(of: comparingMultiple) { _, active in
                if active { dustEditor.enabled = false; dustTask?.cancel(); dustGeneration = UUID(); dustEditor.busy = false }
            }

            .focusedSceneValue(\.editorUndo, undoActions)
            .focusedSceneValue(\.editorPanel, Binding<EditorPanel>(get: { panel }, set: { selectPanel($0) }))
            .focusedSceneValue(\.startTutorial, { startTutorial() })
            .focusedSceneValue(\.toggleEditorPicker, pickerShortcutAction)
            #if os(macOS)
            #if DEBUG
            .focusedSceneValue(\.showLUTVisualizer, comparingMultiple || development == nil || loading ? nil : { lutVisualizer.open(lutVisualizerInput) })
            .onChange(of: lutVisualizerInput) { _, input in lutVisualizer.update(input) }
            .onDisappear { lutVisualizer.close() }
            .focusedSceneValue(\.variationExport, comparingMultiple || development == nil || loading ? nil : { beginExportOptions(variation: true) })
            #endif
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
            .task {
                while !Task.isCancelled {
                    turbo.refresh(policy: autoTurbo)
                    do { try await Task.sleep(for: .seconds(2)) } catch { break }
                }
            }
            .task(id: TurboMode.Request(enabled: turbo.enabled, current: sourceURL,
                files: browserModel.visibleFiles.map(\.url),
                rawFiles: Set(browserModel.visibleFiles.filter(\.isRAW).map(\.url)),
                busy: loading || comparingMultiple || exporting, film: lockedFilm, canvas: overviewCanvas), priority: .utility) {
                await turbo.preload(.init(enabled: turbo.enabled, current: sourceURL,
                    files: browserModel.visibleFiles.map(\.url),
                rawFiles: Set(browserModel.visibleFiles.filter(\.isRAW).map(\.url)),
                    busy: loading || comparingMultiple || exporting, film: lockedFilm, canvas: overviewCanvas), overrides: batchRecipeOverrides)
            }
            .task(id: ComparisonRequest(inputs: comparingMultiple ? comparisonInputs : [], revision: comparisonReload, listing: browserModel.listingRevision, canvas: previewCanvas)) {
                guard comparingMultiple else { comparison.stop(); return }
                let rows = comparisonInputs.count > 2 ? 2.0 : 1.0
                comparison.start(comparisonInputs, film: comparingSnapshots ? nil : lockedFilm,
                    canvas: CGSize(width: previewCanvas.width / 2, height: previewCanvas.height / rows))
            }
            .onChange(of: comparingMultiple) { _, active in
                if active { commitHistory(); pickingWhiteBalance = false; confirmingPreset = nil; previewHover.position = nil; previewDetails.removeAll() }
            }
            .onChange(of: browserModel.directory) { _, _ in comparisonFiles = []; comparisonSnapshots = [] }
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
            .onChange(of: sourceURL) { _, url in
                if url == nil { comparisonFiles = []; comparisonSnapshots = [] }
            }
            .onChange(of: exportSettings) { _, settings in settings.remember() }
            .onChange(of: mapping.color.monochrome) { _, _ in pickingWhiteBalance = false }
            .onChange(of: mapping.blackAndWhite.isEnabled) { _, _ in
                pickingWhiteBalance = false
            }
            .onChange(of: panel) { _, _ in
                if panel != .transform { commitTransform() }
                pickingWhiteBalance = false
                adjustingTone = false
                adjustingWhitePoint = false
                toneLocatorImage = nil
                comparingChromaRange = false; comparingColor = false
                comparingEffects = false; comparingCrossProcessing = false
                let requested = pendingPicker
                pendingPicker = nil
                if panel == .tone, let requested { togglePicker(requested) }
            }
            .onChange(of: development?.id) { _, _ in
                comparingOriginal = false
                pendingPicker = nil
                pickingWhiteBalance = false
                adjustingTone = false
                adjustingWhitePoint = false
                toneLocatorImage = nil
                comparingChromaRange = false; comparingColor = false
                comparingEffects = false; comparingCrossProcessing = false
            }
            .onChange(of: mapping.white) { _, white in
                if mapping.tonePosition > white {
                    mapping.tonePosition = white
                    mapping.setAutomaticHDRTarget()
                }
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
            .task(id: "\(isolatingRAW)-\(doubleSource)-\(development?.id.uuidString ?? "")-\(overviewCanvas.width)x\(overviewCanvas.height)") {
                guard isolatingRAW, let url = activeRAWURL else { isolatedRAWDevelopment = nil; return }
                do {
                    var settings = activeRAWSettings.wrappedValue
                    settings.decoderMode = rawSettings.decoderMode
                    let localGeometry = settings.orientation
                    let firstGeometry = rawSettings.orientation
                    let firstURL: URL? = sourceURL.flatMap { url in mapping.doubleExposure?.urls(relativeTo: url).first }
                    let second = doubleSource == 1
                    if second { settings.orientation = SourceOrientation() }
                    let worker = RAWDeveloper(colorSpace: colorSpace, rawSettings: settings, rawWhiteBalance: activeRAWBalance.wrappedValue, interactive: true)
                    let source = try await worker.develop(url, previewCanvas: overviewCanvas, progressive: true)
                    let overview = if second, let firstURL {
                        try await worker.alignSecondPreview(source, firstURL: firstURL, firstGeometry: firstGeometry, secondGeometry: localGeometry)
                    } else { source }
                    try Task.checkCancellation()
                    isolatedRAWDevelopment = overview
                    if !source.fullResolutionReady {
                        // Same progressive decode and bounded source cache as an ordinary file.
                        let full = try await worker.prepareFullResolution(source)
                        let displayed = if second, let firstURL {
                            try await worker.alignSecondPreview(full, firstURL: firstURL, firstGeometry: firstGeometry, secondGeometry: localGeometry)
                        } else { full }
                        try Task.checkCancellation()
                        isolatedRAWDevelopment = displayed
                    }
                } catch is CancellationError {} catch { errorMessage = error.localizedDescription }
            }
            .task(id: DustSourceRequest(source: development?.id, spots: mapping.dustSpots ?? [], loading: loading)) {
                guard !loading, let current = development, current.dustSpots != (mapping.dustSpots ?? []) else { return }
                let spots = mapping.dustSpots ?? []
                do {
                    try await Task.sleep(for: .milliseconds(150))
                    await fullSourceWorker.discardSourcePixels()
                    try Task.checkCancellation()
                    let rebuilt = try await developer.replacingDust(current, spots: spots, canvas: overviewCanvas)
                    try Task.checkCancellation()
                    guard development?.id == current.id, (mapping.dustSpots ?? []) == spots else { return }
                    previewDetails.removeAll()
                    development = rebuilt
                    configureDustEditor()
                    if dustEditor.enabled, let spot = dustEditor.selectedSpot { sampleDust(spot, fit: false) }
                } catch is CancellationError {} catch { errorMessage = error.localizedDescription }
            }
            .task(id: PreviewRequest(mapping: previewMapping,
                                     sourceID: previewDevelopment?.id, loading: loading || comparingMultiple, canvas: overviewCanvas, lutRevision: lutRevision,
                                     refinementReady: overviewRefinementReady)) {
                guard let development = previewDevelopment, !loading, !comparingMultiple, confirmingPreset == nil,
                      development.dustSpots == (previewMapping.dustSpots ?? []) else { return }
                do {
                    let renderedMapping = previewMapping
                    let canvas = overviewCanvas
                    if canvas != renderedCanvas { try await Task.sleep(for: .milliseconds(100)) }
                    let source = try await developer.overview(development, canvas: canvas)
                    let images = try await developer.previews(source, mapping: renderedMapping, sourceURL: development.url, sourceSize: CGSize(width: development.width, height: development.height))
                    try Task.checkCancellation()
                    guard self.previewDevelopment?.id == development.id,
                          previewMapping == renderedMapping, !loading else { return }
                    renderedPreviewImages = images
                    openingImage = nil
                    RAWImageCache.shared.rememberDisplay(images.sdr, sourceID: development.id)
                    measuredPreviewSourceID = development.id
                    self.renderedMapping = renderedMapping
                    renderedCanvas = canvas
                    previewRevision = UUID()

                } catch is CancellationError {
                    // A newer drag position supersedes this render.
                } catch { errorMessage = error.localizedDescription }
            }
            .task(id: FullSourceRequest(source: development?.id, previewReady: renderedPreviewImages != nil,
                loading: loading || comparingMultiple || development?.dustSpots != (mapping.dustSpots ?? []))) {
                guard !comparingMultiple, !loading, renderedPreviewImages != nil, let current = development,
                      !current.fullResolutionReady, current.dustSpots == (mapping.dustSpots ?? []) else { return }
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
            .task(id: HistogramRequest(sourceID: previewDevelopment?.id, loading: loading || comparingMultiple, previewReady: previewImages != nil, bins: histogramBins)) {
                histogramError = nil
                guard let development = previewDevelopment, !loading, !comparingMultiple, previewImages != nil else {
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
                guard !comparingMultiple else { return }
                finishDeferredEdit()
                editHistory.flush()
                if !loading, development != nil, !cropping { deferredEditBefore = currentRecipe }
                editHistory.interacting = true
            }, ended: {
                guard !comparingMultiple else { return }
                editHistory.interacting = false
                if !cropping { commitHistory() }
            }))
            .background(OriginalCompareShortcut(active: $comparingOriginal,
                enabled: !comparingMultiple && development != nil && !loading && !cropping))
            .background(leftPanelShortcuts.opacity(0).frame(width: 0, height: 0).accessibilityHidden(true))
            #if os(macOS)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                editHistory.interacting = false
                if !cropping { commitHistory() }
            }
            .background(FileNavigationShortcut(navigate: navigateFile).frame(width: 0, height: 0))
            #endif
            .navigationTitle("")
            #if os(macOS)
            .sheet(isPresented: $showingBatchExport) {
                if let directory = browserModel.directory { BatchExportView(directory: directory, film: lockedFilm, recipeOverrides: batchRecipeOverrides, pendingURLs: browserPendingURLs, queue: exportQueue) }
            }
            #endif
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
            .sheet(item: $exportSession, onDismiss: {
                #if os(macOS)
                let window = exportPresentationWindow
                exportPresentationWindow = nil
                if let prepared = pendingSingleExport {
                    pendingSingleExport = nil
                    chooseExportDestination(prepared.plan, worker: prepared.worker, window: window)
                }
                #endif
            }) { session in
                    HEIFExportOptions(settings: $exportSettings, width: session.development.width,
                                      height: session.development.height, hdrEnabled: session.recipe.mapping.hdrEnabled,
                                      sourceURL: session.development.url, mapping: session.recipe.mapping,
                                      colorSpace: session.recipe.colorSpace,
                                      rawSettings: session.recipe.rawSettings ?? session.development.rawDefaults ?? RAWSettings(),
                                      variationGrid: variationExportMode ? $variationGrid : nil,
                                      save: { prepareExport(development: session.development, recipe: session.recipe, worker: $0) })
            }
            .fileExporter(isPresented: $showingSave, document: exportDocument,
                          contentType: exportContentType, defaultFilename: exportName) { (result: Result<URL, Error>) in
                finishFileExport(result)
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { (result: Result<URL, Error>) in
                switch result {
                case .success(let url):
                    openExplicitFile(url)
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
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                changeDirectory(url, choose: true)
            } else { openExplicitFile(url) }
        }).frame(width: 0, height: 0))
        #endif
        #if os(macOS)
        .modifier(ShellWindowChrome())
        .frame(minWidth: EditorSectionLayout.minimumShellWidth, minHeight: 600)
        #endif
    }
    private func openExplicitFile(_ url: URL) {
        requestDiscard {
            #if os(macOS)
            RecentOpenItems.shared.record(url, folder: false)
            #endif
            load(url, resetEdits: true)
        }
    }

    private func load(_ url: URL, resetEdits: Bool, onLoaded: (() -> Void)? = nil) {
        #if os(macOS)
        if resetEdits { SidecarFolderAccess.shared.requestIfNeeded(for: url) }
        #endif
        openingTask?.cancel()
        quickOpeningTask?.cancel()
        commitHistory()
        if resetEdits {
            // Dismiss comparison on an explicit navigation, never when that
            // navigation's asynchronous recipe/source preparation completes.
            comparisonFiles = []; comparisonSnapshots = []
            confirmingPreset = nil
            rememberCurrentEdits()
        }
        if resetEdits { cropping = false; cropRatioPosition = 5; cropTransform = CropTransform(); cropPolygon = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)] }
        let requestID = UUID()
        openingID = requestID
        if resetEdits {
            openingImage = RAWImageCache.shared.firstDisplay(for: url)
            if openingImage == nil {
                quickOpeningTask = Task {
                    let image = await QuickOpeningPreview.image(url, canvas: overviewCanvas)
                    guard !Task.isCancelled, openingID == requestID, renderedPreviewImages == nil else { return }
                    openingImage = image
                }
            }
        }
        sourceURL = url
        filename = url.lastPathComponent
        loading = true
        if resetEdits { doubleSource = 0; isolatedRAWDevelopment = nil; mapping = ToneMapping(); savedRecipe = nil; recipeSourceURL = nil; baselineRecipe = nil; namedSnapshots = []; savedSnapshotDate = nil }
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
        openingTask = Task {
            defer {
                if openingID == requestID {
                    if recipeSourceURL == url, development != nil {
                        editHistory.activate(url, recipe: currentRecipe)
                    }
                    loading = false
                    if recipeSourceURL == url, development != nil {
                        if resetEdits { applyLockedFilm() }
                        onLoaded?()
                    }
                }
            }
            do {
                // Allow SwiftUI to present the provisional cached bitmap before
                // recipe/default preparation starts on the main actor.
                await Task.yield()
                guard openingID == requestID, !Task.isCancelled else { return }
                var restored: DevelopmentRecipe?
                let draft = resetEdits ? pendingEdits.entry(for: url) : nil
                if resetEdits {
                    do { restored = try await RecipeStore.shared.load(for: url) }
                    catch {
                        guard openingID == requestID, !Task.isCancelled else { return }
                        errorMessage = String(localized: "Could not restore saved edits: \(error.localizedDescription)")
                    }
                    guard openingID == requestID, !Task.isCancelled else { return }
                    if let draft {
                        colorSpace = draft.recipe.colorSpace
                        mapping = draft.recipe.mapping
                        savedRecipe = draft.savedRecipe
                    } else if let restored {
                        colorSpace = restored.colorSpace
                        mapping = restored.mapping
                        savedRecipe = restored
                    } else {
                        let space = try await RAWDeveloper().suggestedColorSpace(for: url)
                        guard openingID == requestID, !Task.isCancelled else { return }
                        colorSpace = space
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
                    guard openingID == requestID, !Task.isCancelled else { return }
                    let resolver = RAWDeveloper(colorSpace: colorSpace)
                    var recipe = try await resolver.resolveExportRecipe(url, recipe: target.recipe, isRAW: target.isRAW,
                        maximizeRange: UserDefaults.standard.bool(forKey: RAWSettings.maximizeRangePreferenceKey))
                    guard openingID == requestID, !Task.isCancelled else { return }
                    if target.isRAW, let preset { recipe = preset.applying(to: recipe) }
                    initialRecipe = recipe
                    options = recipe.rawSettings
                    mapping = recipe.mapping
                }
                if resetEdits || interactiveSpace != colorSpace {
                    developer = RAWDeveloper(colorSpace: colorSpace, rawSettings: options, rawWhiteBalance: mapping.rawWhiteBalance, doubleExposure: mapping.doubleExposure, interactive: true)
                    fullSourceWorker = RAWDeveloper(colorSpace: colorSpace, rawSettings: options, rawWhiteBalance: mapping.rawWhiteBalance, doubleExposure: mapping.doubleExposure, interactive: true)
                    detailWorker = RAWDeveloper(colorSpace: colorSpace, interactive: true)
                    interactiveSpace = colorSpace
                } else {
                    await developer.updateRAWSettings(options, whiteBalance: mapping.rawWhiteBalance, doubleExposure: mapping.doubleExposure)
                    guard openingID == requestID, !Task.isCancelled else { return }
                    await fullSourceWorker.updateRAWSettings(options, whiteBalance: mapping.rawWhiteBalance, doubleExposure: mapping.doubleExposure)
                }
                guard openingID == requestID, !Task.isCancelled else { return }
                histogramWorker = RAWDeveloper(colorSpace: colorSpace, rawSettings: options, rawWhiteBalance: mapping.rawWhiteBalance)
                let loaded = try await developer.develop(url, previewCanvas: overviewCanvas, progressive: true, dustSpots: mapping.dustSpots ?? [])
                guard openingID == requestID, !Task.isCancelled else { return }
                let defaults = loaded.rawDefaults ?? RAWSettings()
                rawSettings = options?.resolved(using: defaults) ?? defaults
                if resetEdits {
                    if var saved = savedRecipe, loaded.isRAW {
                        saved.rawSettings = rawSettings
                        savedRecipe = saved
                    }
                }
                if initializeEdits {
                    mapping = initialRecipe?.mapping ?? ToneMapping.fresh(isRAW: loaded.isRAW, sourceHeadroom: loaded.sourceHeadroom, sourceSize: CGSize(width: loaded.width, height: loaded.height))
                }
                if loaded.isRAW, mapping.rawWhiteBalance == nil, let reference = loaded.whitePoint {
                    mapping.rawWhiteBalance = RAWWhiteBalance(reference)
                    if var saved = savedRecipe {
                        saved.mapping.rawWhiteBalance = mapping.rawWhiteBalance
                        savedRecipe = saved
                    }
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
                if resetEdits { asShotBalance = loaded.isRAW ? try? RAWWhiteBalance.asShot(mapping.doubleExposure?.urls(relativeTo: url).first ?? url) : nil }
                previewDetails.removeAll()
                development = loaded

                filename = url.lastPathComponent
            } catch is CancellationError {
            } catch {
                guard openingID == requestID, !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func applyLockedFilm() {
        guard let lockedFilm else { return }
        let updated = lockedFilm.applying(to: currentRecipe)
        guard updated.mapping != mapping || updated.rawSettings != currentRecipe.rawSettings else { return }
        let reload = updated.mapping.rawWhiteBalance != mapping.rawWhiteBalance || updated.rawSettings != currentRecipe.rawSettings || updated.mapping.doubleExposure != mapping.doubleExposure
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
                    if maximizeRange { resetRAW = try await worker.maximumRAWRange(mapping.doubleExposure?.urls(relativeTo: development.url).first ?? development.url) }
                    else { resetRAW.values[.exposure] = 0 }
                    if let preset, preset.selection.contains(.exposure), let exposure = preset.recipe.rawSettings?.values[.exposure] {
                        resetRAW.values[.exposure] = exposure
                    }
                }
                guard self.development?.id == development.id, mapping == original,
                      rawSettings == originalRAW else { return }
                var baseline = DevelopmentRecipe(colorSpace: colorSpace,
                    mapping: .fresh(isRAW: development.isRAW, sourceHeadroom: development.sourceHeadroom, sourceSize: CGSize(width: development.width, height: development.height)))
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

    private func openSnapshotReference(_ key: String) {
        #if os(macOS)
        guard let url = recipeSourceURL else { return }
        let recipe: DevelopmentRecipe?
        let title: String
        if key == "saved" { recipe = savedRecipe ?? baselineRecipe; title = String(localized: "Saved Edit") }
        else if key == "unsaved" { recipe = snapshotSession.draft?.recipe; title = String(localized: "Unsaved Edit") }
        else { let item = namedSnapshots.first { $0.id.uuidString == key }; recipe = item?.edit.recipe; title = item?.name ?? key }
        guard let recipe else { return }
        ReferenceWindow.open(url: url, recipe: recipe, film: lockedFilm, title: title, link: previewViewport.referenceLink)
        #endif
    }

    private func createSnapshot(_ name: String) {
        guard !comparingMultiple else { return }
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
            #if os(macOS)
            if choose { RecentOpenItems.shared.record(url, folder: true) }
            #endif
            if choose { browserModel.choose(url) } else { browserModel.navigate(to: url) }
            return
        }
        requestDiscard {
            #if os(macOS)
            if choose { RecentOpenItems.shared.record(url, folder: true) }
            #endif
            openingTask?.cancel(); quickOpeningTask?.cancel()
            openingID = UUID(); openingImage = nil; loading = false
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
        LinearHistogram(sourceOnly: isolatingRAW, development: previewDevelopment, histogram: histogram,
                        histogramError: histogramError, binCount: $histogramBins,
                        mapping: isolatingRAW ? .constant(previewMapping) : $mapping, sdrSource: previewImages?.sdr,
                        revision: previewRevision, colorSpace: colorSpace, hdrPreview: hdrPreview,
                        showingSDR: isolatingRAW ? .constant(false) : sdrHistogramBinding,
                        hoverTransform: !showingSDRHistogram && !cropping ? previewMapping.transform : nil,
                        onWhitePointEditingChanged: { editing in
                            adjustingWhitePoint = editing
                            toneLocatorImage = nil
                        })
    }

    private var tonePanel: some View {
    VStack(spacing: EditorSectionLayout.spacing) {
        ToneSectionView(mapping: $mapping, sourceISO: development?.metadata.iso,
            rawExposure: development?.isRAW == true ? Double(rawSettings.values[.exposure] ?? 0) : 0,
            resetting: resettingTone, reset: resetTone,
            onToneChanged: { tutorial.record(.tone) },
            onContrastChanged: { tutorial.record(.contrast) },
            onToneEditingChanged: { editing in
                adjustingTone = editing
                if !editing { toneLocatorImage = nil }
            },
            onISOEditingChanged: { editing in
                adjustingWhitePoint = editing
                toneLocatorImage = nil
            })
        if !mapping.color.monochrome || mapping.rawWhiteBalance != nil {
        VectorscopeView(source: development?.preview,
                        hoverSource: previewImages?.sdr,
                        hoverRevision: previewRevision,
                        revision: development?.id ?? previewRevision,
                        colorSpace: colorSpace, mapping: Binding(
                    get: { var value = previewMapping; if mapping.doubleExposure != nil { value.rawWhiteBalance = nil }; return value },
                    set: { mapping.whiteBalance = $0.whiteBalance; if mapping.doubleExposure == nil { mapping.rawWhiteBalance = $0.rawWhiteBalance } }), pickingWhiteBalance: $pickingWhiteBalance,
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
                activeRAWBalance.wrappedValue = try resetDefaults.mapping.rawWhiteBalance ?? RAWWhiteBalance.asShot(activeRAWURL ?? sourceURL)
                mapping.whiteBalance = resetDefaults.mapping.whiteBalance
                commitRAWWhiteBalance()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func resetActiveRAW() {
        guard let url = activeRAWURL, let document = sourceURL else { return }
        let selected = doubleSource
        Task {
            do {
                let worker = RAWDeveloper(colorSpace: colorSpace)
                let fresh = DevelopmentRecipe(colorSpace: colorSpace, mapping: .fresh(isRAW: true, sourceHeadroom: 1))
                let resolved = try await worker.resolveExportRecipe(url, recipe: fresh, isRAW: true, maximizeRange: false)
                let defaults = EditLibrary.shared.rawDefaultPreset?.applying(to: resolved) ?? resolved
                guard sourceURL == document, doubleSource == selected else { return }
                if var settings = defaults.rawSettings {
                    if mapping.doubleExposure == nil || selected != 1 {
                        settings.orientation = activeRAWSettings.wrappedValue.orientation
                    }
                    activeRAWSettings.wrappedValue = settings
                }
                load(document, resetEdits: false)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func maximizeRAWRange() {
        guard let development, development.isRAW, !loading, !maximizingRAWRange else { return }
        maximizingRAWRange = true
        let originalSettings = activeRAWSettings.wrappedValue
        let originalBalance = activeRAWBalance.wrappedValue
        let worker = RAWDeveloper(colorSpace: colorSpace, rawSettings: originalSettings, rawWhiteBalance: originalBalance)
        Task {
            defer { maximizingRAWRange = false }
            do {
                let settings = try await worker.maximumRAWRange(activeRAWURL ?? development.url)
                guard self.development?.id == development.id, !loading,
                      activeRAWSettings.wrappedValue == originalSettings, activeRAWBalance.wrappedValue == originalBalance else { return }
                activeRAWSettings.wrappedValue = settings
                load(development.url, resetEdits: false)
            } catch {
                if self.development?.id == development.id { errorMessage = error.localizedDescription }
            }
        }
    }

    private func applyRAWBalancePreset(_ temperature: Float) {
        guard !loading, let sourceURL else { return }
        activeRAWBalance.wrappedValue = RAWWhiteBalance(temperature: temperature, tint: 0)
        load(sourceURL, resetEdits: false)
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
            var input = currentRecipe.transferable
            input.mapping.rawWhiteBalance = activeRAWBalance.wrappedValue
            let baked = try RAWWhiteBalance.baked(input, source: activeRAWURL ?? development.url)
            if baked.mapping.whiteBalance != WhiteBalance() {
                errorMessage = String(localized: "White balance limits reached. The remaining adjustment has been retained in RGB gains.")
            }
            guard baked.mapping != mapping else { return }
            mapping.whiteBalance = baked.mapping.whiteBalance
            activeRAWBalance.wrappedValue = baked.mapping.rawWhiteBalance
            load(development.url, resetEdits: false)
        } catch { errorMessage = error.localizedDescription }
    }

    private var pickerShortcutAction: ((EditorPickerTool) -> Void)? {
        guard !comparingMultiple, development != nil, !loading, !mapping.blackAndWhite.isEnabled, !mapping.color.monochrome else { return nil }
        return { togglePicker($0) }
    }

    private func togglePicker(_ tool: EditorPickerTool) {
        guard !comparingMultiple, development != nil, !loading, !mapping.blackAndWhite.isEnabled, !mapping.color.monochrome else { return }
        if panel != .tone {
            pendingPicker = tool
            panel = .tone
            return
        }
        pickingWhiteBalance.toggle()
    }

    private func navigateFile(_ direction: Int) -> Bool {
        guard !comparingMultiple else { return false }
        guard !fileActionBusy, !cropping else { return false }
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
        guard !comparingMultiple || action != .copyEdit else { return }
        guard !fileActionBusy else { return }
        if action == .reference {
            #if os(macOS)
            ReferenceWindow.open(url: url, recipe: batchRecipeOverrides[url.standardizedFileURL], film: lockedFilm,
                title: url.lastPathComponent, link: previewViewport.referenceLink)
            #endif
            return
        }
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
                case .deleteEdit, .showInFinder, .reference, .doubleExposure: break
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
            updatedRecipe.applySecondRAW(from: pastedSettings.mapping, raw: pastedSettings.rawSettings, selection: selection)
            let session = SnapshotSession(selected: "unsaved", draft: SnapshotEdit(updatedRecipe), draftModifiedAt: Date())
            updatedRecipe.draftSnapshot = session.persistedDraft
            editHistory.record(url, from: destination, to: updatedRecipe, name: String(localized: "Paste Edits"))
            pendingEdits.remember(url: url, recipe: updatedRecipe,
                baseline: draft?.baseline ?? target.recipe, saved: draft?.savedRecipe ?? target.savedRecipe, session: session)
        } else {
            guard development != nil else { return }
                    comparingChromaRange = false; comparingColor = false
            comparingEffects = false; comparingCrossProcessing = false
            pickingWhiteBalance = false
            let previousRAWSettings = rawSettings
            if development?.isRAW == true,
               let updated = selection.applyingRAW(pastedSettings.rawSettings, to: rawSettings) {
                rawSettings = updated
            }
            let previousRAWBalance = mapping.rawWhiteBalance
            mapping = pastedSettings.applying(selection, to: mapping, reference: development?.whitePoint, space: colorSpace)
            var applied = currentRecipe
            applied.applySecondRAW(from: pastedSettings.mapping, raw: pastedSettings.rawSettings, selection: selection)
            mapping.doubleExposure = applied.mapping.doubleExposure
            editHistory.observe(currentRecipe, name: String(localized: "Paste Edits"))
            editHistory.flush()
            if mapping.doubleExposure != nil || mapping.rawWhiteBalance != previousRAWBalance || rawSettings != previousRAWSettings { commitRAWWhiteBalance() }
        }
    }

    private func createDoubleExposure(_ urls: [URL]) {
        guard urls.count == 2 else { return }
        fileActionBusy = true
        Task {
            defer { fileActionBusy = false }
            do {
                var recipes: [DevelopmentRecipe] = []
                for url in urls {
                    let target = try await BrowserRecipeTarget.fresh(url)
                    guard target.isRAW, !DoubleExposure.isDocument(url) else { throw DoubleExposure.Failure.invalid }
                    let worker = RAWDeveloper(colorSpace: .displayP3)
                    let fresh = try await worker.resolveExportRecipe(url, recipe: target.recipe, isRAW: true,
                        maximizeRange: UserDefaults.standard.bool(forKey: RAWSettings.maximizeRangePreferenceKey))
                    recipes.append(EditLibrary.shared.rawDefaultPreset?.applying(to: fresh) ?? fresh)
                }
                var recipe = recipes[0]
                let folder = urls[0].deletingLastPathComponent()
                recipe.mapping.doubleExposure = DoubleExposure(first: urls[0].lastPathComponent, second: urls[1].lastPathComponent,
                    secondRAW: recipes[1].rawSettings ?? RAWSettings(), secondBalance: recipes[1].mapping.rawWhiteBalance)
                recipe.mapping.setAutomaticHDRTarget()
                recipe = lockedFilm?.applying(to: recipe) ?? recipe
                var suffix = 1
                var destination = folder.appendingPathComponent("Double Exposure.double.darkmelon.xmp")
                while FileManager.default.fileExists(atPath: destination.path) {
                    suffix += 1; destination = folder.appendingPathComponent("Double Exposure \(suffix).double.darkmelon.xmp")
                }
                // Validate actual decoder extents before creating the document.
                let worker = RAWDeveloper(colorSpace: recipe.colorSpace, rawSettings: recipe.rawSettings,
                    rawWhiteBalance: recipe.mapping.rawWhiteBalance, doubleExposure: recipe.mapping.doubleExposure)
                _ = try await worker.develop(destination, progressive: true)
                try await RecipeStore.shared.save(recipe, for: destination)
                browserModel.navigate(to: folder)
                load(destination, resetEdits: true)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func performMultipleFileAction(_ action: BrowserFileAction, urls: [URL]) {
        guard !fileActionBusy, !urls.isEmpty else { return }
        if action == .doubleExposure { createDoubleExposure(urls); return }
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
                if DoubleExposure.isDocument(url) {
                    sourceURL = nil; recipeSourceURL = nil; baselineRecipe = nil; savedRecipe = nil
                    namedSnapshots = []; savedSnapshotDate = nil; snapshotSession = SnapshotSession()
                    development = nil; isolatedRAWDevelopment = nil; renderedPreviewImages = nil
                    previewDetails.removeAll(); histogram = nil; mapping = ToneMapping()
                    comparisonFiles = []; comparisonSnapshots = []; filename = "Dark Melon"
                } else {
                    baselineRecipe = currentRecipe
                    load(url, resetEdits: true)
                }
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
        let session = ImageExportSession(development: source, recipe: lockedFilm?.applying(to: original) ?? original)
        #if os(macOS)
        // Capture the editor before the options sheet takes focus. Attaching the
        // save panel to that closing sheet would dismiss the save panel with it.
        var window = NSApp.keyWindow ?? NSApp.mainWindow
        while let parent = window?.sheetParent { window = parent }
        exportPresentationWindow = window
        #endif
        exportSession = session
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

private struct PreviewRequest: Equatable {
    let mapping: ToneMapping
    let sourceID: UUID?
    let loading: Bool
    let canvas: CGSize
    var lutRevision: Int = 0
    var refinementReady = false
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




private struct ToneLocatorRequest: Equatable {
    let active: Bool
    let clipping: Bool
    let mapping: ToneMapping
    let revision: UUID
    let hdr: Bool
}





private struct FullSourceRequest: Equatable {
    let source: UUID?
    let previewReady: Bool
    let loading: Bool
}

private struct ImageExportSession: Identifiable {
    let id = UUID()
    let development: RAWDevelopment
    let recipe: DevelopmentRecipe
}

private struct DustSourceRequest: Equatable {
    let source: UUID?
    let spots: [DustSpot]
    let loading: Bool
}
