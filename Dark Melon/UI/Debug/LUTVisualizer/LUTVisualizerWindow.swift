#if DEBUG && os(macOS)
import SwiftUI
import AppKit

nonisolated struct LUTVisualizerInput: Equatable, Sendable {
    let mapping: ToneMapping
    let colorSpace: ProcessingColorSpace
    let configuration: LUTConfiguration?

    init(mapping: ToneMapping, colorSpace: ProcessingColorSpace) {
        self.mapping = SDRLUT.pointwiseMapping(mapping)
        self.colorSpace = colorSpace
        configuration = mapping.lutID.map { LUTStore.shared.configuration(for: $0) }
    }
}

/// Each editor owns its visualizer, so separate editor windows never share an active transform.
@MainActor final class LUTVisualizerWindow: NSWindowController, NSWindowDelegate {
    private var model: LUTVisualizerModel?

    init() { super.init(window: nil) }
    required init?(coder: NSCoder) { fatalError() }

    func open(_ input: LUTVisualizerInput) {
        if window == nil {
            let model = LUTVisualizerModel()
            self.model = model
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "LUT Visualizer"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: LUTVisualizerView(model: model) { [weak self, weak model] in
                model?.save(in: self?.window)
            })
            self.window = window
            window.center()
        }
        update(input)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func update(_ input: LUTVisualizerInput) { model?.update(input) }

    func windowWillClose(_ notification: Notification) {
        model?.stop()
        window?.contentView = nil
        model = nil
        window = nil
    }
}
#endif
