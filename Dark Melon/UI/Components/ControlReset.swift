import SwiftUI
#if os(macOS)
import AppKit
#endif

extension EnvironmentValues {
    @Entry var controlResetAction: (() -> Void)? = nil
    @Entry var resetRAWSettings: RAWSettings? = nil
}
extension View {
    func controlReset(_ action: @escaping () -> Void) -> some View {
        environment(\.controlResetAction, action)
    }
    func resetInteraction(_ action: (() -> Void)?) -> some View {
        modifier(ControlResetInteraction(action: action))
    }
}

private struct ControlResetInteraction: ViewModifier {
    @Environment(\.isEnabled) private var enabled
    let action: (() -> Void)?
    func body(content: Content) -> some View {
        content
            .background {
                #if os(macOS)
                if let action, enabled { ResetClickSurface(action: action).allowsHitTesting(false) }
                #endif
            }
            #if !os(macOS)
            .simultaneousGesture(TapGesture(count: 2).onEnded { if enabled { action?() } })
            #endif
            .accessibilityAction(named: Text("Reset")) { if enabled { action?() } }
    }
}

#if os(macOS)
/// Only intercept reset clicks; ordinary presses and drags reach the control.
private struct ResetClickSurface: NSViewRepresentable {
    let action: () -> Void
    func makeNSView(context: Context) -> Surface { Surface() }
    func updateNSView(_ view: Surface, context: Context) { view.action = action }
    static func dismantleNSView(_ view: Surface, coordinator: ()) { view.stopMonitoring() }
    final class Surface: NSView {
        var action: (() -> Void)?
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      !self.isHiddenOrHasHiddenAncestor,
                      event.type == .rightMouseDown || event.clickCount == 2,
                      self.bounds.intersection(self.visibleRect).contains(self.convert(event.locationInWindow, from: nil)) else { return event }
                self.action?()
                return nil
            }
        }
        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
#endif
