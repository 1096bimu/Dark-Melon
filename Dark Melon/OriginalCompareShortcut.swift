import SwiftUI
#if os(macOS)
import AppKit

/// A key-up-aware shortcut that never intercepts typing or Command-C.
struct OriginalCompareShortcut: NSViewRepresentable {
    @Binding var active: Bool
    var enabled: Bool
    func makeNSView(context: Context) -> KeyView { KeyView() }
    func updateNSView(_ view: KeyView, context: Context) {
        view.changed = { active = $0 }
        view.enabled = enabled
        if !enabled { view.release() }
    }
    static func dismantleNSView(_ view: KeyView, coordinator: ()) { view.release() }

    final class KeyView: NSView {
        var changed: (Bool) -> Void = { _ in }
        var enabled = false
        var held = false
        private var monitor: Any?
        private var observer: NSObjectProtocol?
        override init(frame: NSRect) {
            super.init(frame: frame)
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                guard let self else { return event }
                if event.keyCode == 8 && event.type == .keyUp && held {
                    release(); return nil
                }
                guard enabled, window?.isKeyWindow == true, event.window === window,
                      event.keyCode == 8, event.type == .keyDown,
                      event.modifierFlags.intersection([.command,.control,.option,.shift]).isEmpty,
                      !(window?.firstResponder is NSTextView), window?.attachedSheet == nil else { return event }
                if !held { held = true; changed(true) }
                return nil
            }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.release() }
                }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        func release() { if held { held = false; changed(false) } }
        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
#else
struct OriginalCompareShortcut: View {
    @Binding var active: Bool
    var enabled: Bool
    var body: some View { Color.clear.frame(width: 0, height: 0) }
}
#endif
