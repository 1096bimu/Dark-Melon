#if os(macOS)
import SwiftUI
import AppKit

/// Observes the screen containing this preview, rather than the application's main screen.
struct HDRHeadroomNotice: ViewModifier {
    let enabled: Bool
    let peak: Double
    @State private var available: Double?
    @Environment(\.hdrScreenSaverActive) private var dimmed

    func body(content: Content) -> some View {
        content.background(HeadroomProbe(value: $available))
            .overlay(alignment: .bottom) {
                if enabled, !dimmed, let available, peak > available + 0.01 {
                    Label("HDR output exceeds display headroom", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.white)
                        .modifier(PreviewOverlayStyle()).padding(12)
                        .allowsHitTesting(false)
                        .accessibilityValue("\(peak, specifier: "%.2f")× / \(available, specifier: "%.2f")×")
                }
            }
    }
}

private struct HeadroomProbe: NSViewRepresentable {
    @Binding var value: Double?
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        view.report = { value = $0 }
        view.scheduleUpdate()
    }
    final class Probe: NSView {
        var report: ((Double?) -> Void)?
        private var last: Double?
        override init(frame: NSRect) {
            super.init(frame: frame)
            NotificationCenter.default.addObserver(self, selector: #selector(scheduleUpdate), name: NSApplication.didChangeScreenParametersNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(screenChanged(_:)), name: NSWindow.didChangeScreenNotification, object: nil)
        }
        convenience init() { self.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        deinit { NotificationCenter.default.removeObserver(self) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleUpdate() }
        @objc private func screenChanged(_ notification: Notification) {
            if notification.object as? NSWindow === window { scheduleUpdate() }
        }
        @objc func scheduleUpdate() {
            // Publish outside SwiftUI's representable update transaction.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let value = self.window?.screen.map { Double($0.maximumExtendedDynamicRangeColorComponentValue) }
                if value != self.last { self.last = value; self.report?(value) }
            }
        }
    }
}
#endif
