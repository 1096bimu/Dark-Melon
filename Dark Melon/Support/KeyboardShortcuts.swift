import SwiftUI

#if os(macOS)
import AppKit

// MARK: - FileNavigationShortcut

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

// MARK: - BrowserSelectAllShortcut

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

// MARK: - OriginalCompareShortcut

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
