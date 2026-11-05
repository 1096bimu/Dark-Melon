#if os(macOS)
import SwiftUI
import AppKit

/// Track this window's display, independently of window size and the main screen.
struct OverviewDisplayProbe: NSViewRepresentable {
    @Binding var pixels: CGSize?

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        view.report = { pixels = $0 }
        view.scheduleUpdate()
    }

    final class Probe: NSView {
        var report: ((CGSize?) -> Void)?
        private var last: CGSize?

        override init(frame: NSRect) {
            super.init(frame: frame)
            NotificationCenter.default.addObserver(self, selector: #selector(scheduleUpdate), name: NSApplication.didChangeScreenParametersNotification, object: nil)
            for name in [NSWindow.didChangeScreenNotification, NSWindow.didChangeBackingPropertiesNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(windowChanged(_:)), name: name, object: nil)
            }
        }
        convenience init() { self.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        deinit { NotificationCenter.default.removeObserver(self) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleUpdate() }

        @objc private func windowChanged(_ notification: Notification) {
            if notification.object as? NSWindow === window { scheduleUpdate() }
        }

        @objc func scheduleUpdate() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let pixels = self.window?.screen.flatMap {
                    PreviewResolution.displayCanvas(points: $0.frame.size, scale: $0.backingScaleFactor)
                }
                if pixels != self.last { self.last = pixels; self.report?(pixels) }
            }
        }
    }
}
#endif
