#if os(macOS)
import SwiftUI
import AppKit

/// Native viewport synchronization avoids publishing gesture frames through SwiftUI.
@MainActor final class ReferenceViewportLink {
    weak var main: HDRImagePreview.ImageDisplay?
    private var references: [UUID: WeakView] = [:]
    private struct WeakView { weak var view: HDRImagePreview.ImageDisplay? }
    func set(_ view: HDRImagePreview.ImageDisplay, id: UUID, synchronized: Bool) {
        if synchronized {
            let newlyLinked = references[id] == nil
            references[id] = WeakView(view: view)
            if newlyLinked, let main { view.setNormalizedViewport(main.normalizedViewport) }
        } else { references[id] = nil }
    }
    func changed(_ source: HDRImagePreview.ImageDisplay) {
        let state = source.normalizedViewport
        if source !== main { main?.setNormalizedViewport(state) }
        references = references.filter { $0.value.view != nil }
        for value in references.values where value.view !== source { value.view?.setNormalizedViewport(state) }
    }
}

@MainActor final class ReferenceWindow: NSWindowController, NSWindowDelegate {
    private static var windows: [UUID: ReferenceWindow] = [:]
    private let id = UUID()
    private var preparation: Task<Void, Never>?
    private let model = ReferenceImage()
    static func open(url: URL, recipe: DevelopmentRecipe?, film: FilmSettings?, title: String, link: ReferenceViewportLink) {
        let controller = ReferenceWindow(url: url, recipe: recipe, film: film, title: title, link: link)
        windows[controller.id] = controller
        controller.showWindow(nil)
    }
    private init(url: URL, recipe: DevelopmentRecipe?, film: FilmSettings?, title: String, link: ReferenceViewportLink) {
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 900,height: 650),
            styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: ReferenceImageView(model: model, link: link).modifier(HDRScreenSaver()))
        window.center()
        preparation = Task { [weak self] in
            do {
                // Resolve the recipe once, then fully materialize both finished renditions.
                // No source file, sidecar, snapshot, or LUT is needed after preparation.
                let loaded = try await BrowserFileDevelopment.load(url, override: recipe, bins: 256, film: film)
                try Task.checkCancellation()
                let frozen = try await loaded.worker.referenceImages(loaded.development, mapping: loaded.recipe.mapping)
                try Task.checkCancellation()
                self?.model.peak = loaded.recipe.mapping.hdrMax
                self?.model.images = frozen
            } catch is CancellationError {
            } catch { self?.model.error = error.localizedDescription }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    func windowWillClose(_ notification: Notification) {
        preparation?.cancel(); preparation = nil
        model.images = nil
        Self.windows[id] = nil
    }
}

@MainActor @Observable private final class ReferenceImage {
    var peak: Double = 1
    var images: PreviewImages?
    var error: String?
}

private struct ReferenceImageView: View {
    var model: ReferenceImage
    let link: ReferenceViewportLink
    @State private var synchronized = false
    @AppStorage("preview.prefersHDR") private var hdr = true
    var body: some View {
        ZStack {
            Color.black
            if let images = model.images {
                ReferenceCanvas(images: images, hdr: hdr, synchronized: synchronized, link: link)
                    .modifier(HDRHeadroomNotice(enabled: hdr && images.hasHDROutput, peak: model.peak))
            } else if let error = model.error {
                Text(error).foregroundStyle(.secondary).padding()
            } else { ProgressView("Preparing Image…").padding().modifier(PreviewOverlayStyle()) }
        }
        .overlay(alignment: .top) {
            Picker("Comparison", selection: $synchronized) {
                Text("No Sync").tag(false)
                Text("Same Area").tag(true)
            }.pickerStyle(.segmented).frame(width: 240)
                .modifier(PreviewOverlayStyle()).modifier(PreviewOverlayVisibility()).padding(12)
        }
        .frame(minWidth: 320,minHeight: 240)
    }
}

private struct ReferenceCanvas: NSViewRepresentable {
    let images: PreviewImages
    let hdr: Bool
    let synchronized: Bool
    let link: ReferenceViewportLink
    @State private var id = UUID()
    @Environment(\.hdrScreenSaverActive) private var dimmed
    @AppStorage("previewMouseControls") private var mouse = false
    @AppStorage("previewReverseMouseScroll") private var reverse = false
    func makeNSView(context: Context) -> HDRImagePreview.ImageDisplay {
        let view = HDRImagePreview.ImageDisplay(viewport: PreviewViewport())
        view.allowsWhiteBalance = false
        return view
    }
    func updateNSView(_ view: HDRImagePreview.ImageDisplay, context: Context) {
        view.mouseControls = mouse; view.reverseMouseScroll = reverse
        let useHDR = hdr && images.hasHDROutput
        view.display(useHDR ? images.hdr : images.sdr, sdrImage: images.sdr, surface: nil, sdrSurface: nil,
            sourceSize: CGSize(width: images.sdr.width,height: images.sdr.height), detail: nil,
            hdr: useHDR, sourceID: id, screenSaverActive: dimmed)
        link.set(view,id: id,synchronized: synchronized)
        view.viewportChanged = synchronized ? { [weak view] in if let view { link.changed(view) } } : nil
    }
}
#endif
