#if os(macOS)
import SwiftUI
import AppKit

/// Browse photos without consuming arrow keys used by text editors or controls.
struct FileNavigationShortcut: NSViewRepresentable {
    let navigate: (Int) -> Bool

    func makeNSView(context: Context) -> KeyView { KeyView() }
    func updateNSView(_ view: KeyView, context: Context) { view.navigate = navigate }

    final class KeyView: NSView {
        var navigate: (Int) -> Bool = { _ in false }
        private var monitor: Any?

        override init(frame: NSRect) {
            super.init(frame: frame)
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window, window.isKeyWindow, event.window === window,
                      window.attachedSheet == nil, !isHiddenOrHasHiddenAncestor,
                      event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                      event.keyCode == 123 || event.keyCode == 124,
                      !(window.firstResponder is NSTextView),
                      !(window.firstResponder is NSControl) else { return event }
                return navigate(event.keyCode == 123 ? -1 : 1) ? nil : event
            }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
#endif
