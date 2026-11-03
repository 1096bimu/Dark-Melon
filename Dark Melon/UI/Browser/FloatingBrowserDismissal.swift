import SwiftUI
#if os(macOS)
import AppKit
#endif

private struct FloatingBrowserRegions: PreferenceKey {
    static let defaultValue: [Anchor<CGRect>] = []
    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    func floatingBrowserInteractionArea() -> some View {
        anchorPreference(key: FloatingBrowserRegions.self, value: .bounds) { [$0] }
    }
}

struct FloatingBrowserDismissal: ViewModifier {
    let enabled: Bool
    let dismiss: () -> Void

    func body(content: Content) -> some View {
        #if os(macOS)
        content.backgroundPreferenceValue(FloatingBrowserRegions.self) { anchors in
            GeometryReader { geometry in
                OutsideClickMonitor(enabled: enabled, protectedRects: anchors.map { geometry[$0] }, dismiss: dismiss)
            }
        }
        #else
        content
        #endif
    }
}

#if os(macOS)
private struct OutsideClickMonitor: NSViewRepresentable {
    let enabled: Bool
    let protectedRects: [CGRect]
    let dismiss: () -> Void

    func makeNSView(context: Context) -> ClickView { ClickView() }
    func updateNSView(_ view: ClickView, context: Context) {
        view.enabled = enabled
        view.protectedRects = protectedRects
        view.dismiss = dismiss
    }
    static func dismantleNSView(_ view: ClickView, coordinator: ()) { view.stopMonitoring() }

    final class ClickView: NSView {
        var enabled = false
        var protectedRects: [CGRect] = []
        var dismiss: () -> Void = {}
        private var monitor: Any?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                guard let self, self.enabled, let window = self.window,
                      event.window === window, window.attachedSheet == nil,
                      !self.isHiddenOrHasHiddenAncestor else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.visibleRect.contains(point),
                      !self.protectedRects.contains(where: {
                          RoundedRectangle(cornerRadius: EditorSectionLayout.panelCornerRadius).path(in: $0).contains(point)
                      }) else { return event }
                // Let the clicked control receive the event before changing the layout.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.enabled, self.window === window else { return }
                    self.dismiss()
                }
                return event
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
#endif
