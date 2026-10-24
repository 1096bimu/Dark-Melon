#if os(macOS)
import SwiftUI
import AppKit

/// Leave text selection to the field editor; otherwise select the visible browser files.
struct BrowserSelectAllShortcut: NSViewRepresentable {
    let selectAll: () -> Void

    func makeNSView(context: Context) -> KeyView { KeyView() }
    func updateNSView(_ view: KeyView, context: Context) { view.selectFiles = selectAll }

    final class KeyView: NSView {
        var selectFiles: () -> Void = {}
        private var monitor: Any?

        override init(frame: NSRect) {
            super.init(frame: frame)
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window, window.isKeyWindow,
                      event.window === window, window.attachedSheet == nil,
                      !isHiddenOrHasHiddenAncestor,
                      event.charactersIgnoringModifiers?.lowercased() == "a",
                      event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
                      !(window.firstResponder is NSTextView) else { return event }
                selectFiles()
                return nil
            }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
#endif
