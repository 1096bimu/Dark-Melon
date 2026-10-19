#if os(macOS)
import SwiftUI
import AppKit

@MainActor final class SaveLifecycleAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        do {
            for window in sender.windows {
                if let delegate = window.delegate as? FileSaveLifecycle.Coordinator { try delegate.save() }
            }
            return .terminateNow
        } catch {
            NSAlert(error: error).runModal()
            return .terminateCancel
        }
    }
}

/// Preserve SwiftUI's window delegate while gating closure on a successful flush.
struct FileSaveLifecycle: NSViewRepresentable {
    let save: () throws -> Void
    func makeCoordinator() -> Coordinator { Coordinator(save: save) }
    func makeNSView(context: Context) -> Host {
        let view = Host()
        view.coordinator = context.coordinator
        return view
    }
    func updateNSView(_ view: Host, context: Context) {
        context.coordinator.save = save
        if let window = view.window { context.coordinator.attach(to: window) }
    }
    final class Host: NSView {
        weak var coordinator: Coordinator?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { coordinator?.attach(to: window) }
        }
    }
    final class Coordinator: NSObject, NSWindowDelegate {
        var save: () throws -> Void
        private weak var original: (any NSWindowDelegate)?
        private weak var window: NSWindow?
        init(save: @escaping () throws -> Void) { self.save = save }
        func attach(to window: NSWindow) {
            guard window.delegate !== self else { return }
            self.window = window
            original = window.delegate
            window.delegate = self
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            do { try save() }
            catch { NSAlert(error: error).runModal(); return false }
            return original?.windowShouldClose?(sender) ?? true
        }
        func windowWillClose(_ notification: Notification) {
            // Also covers programmatic closes that bypass windowShouldClose.
            do { try save() }
            catch { NSAlert(error: error).runModal() }
            original?.windowWillClose?(notification)
        }
        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (original?.responds(to: selector) ?? false)
        }
        override func forwardingTarget(for selector: Selector!) -> Any? {
            if original?.responds(to: selector) == true { return original }
            return super.forwardingTarget(for: selector)
        }
    }
}
#endif
