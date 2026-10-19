#if os(macOS)
import SwiftUI
import AppKit

@MainActor final class SaveLifecycleAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let delegates = sender.windows.compactMap { $0.delegate as? FileSaveLifecycle.Coordinator }
        for delegate in delegates {
            if !delegate.requestClose() {
                delegates.forEach { $0.resetApproval() }
                return .terminateCancel
            }
        }
        return .terminateNow
    }
}

/// Preserve SwiftUI's window delegate while gating closure on an explicit pending-edit decision.
struct FileSaveLifecycle: NSViewRepresentable {
    let approveClose: () -> Bool
    func makeCoordinator() -> Coordinator { Coordinator(approveClose: approveClose) }
    func makeNSView(context: Context) -> Host {
        let view = Host()
        view.coordinator = context.coordinator
        return view
    }
    func updateNSView(_ view: Host, context: Context) {
        context.coordinator.approveClose = approveClose
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
        var approveClose: () -> Bool
        private var approved = false
        private weak var original: (any NSWindowDelegate)?
        private weak var window: NSWindow?
        init(approveClose: @escaping () -> Bool) { self.approveClose = approveClose }
        func resetApproval() { approved = false }
        func requestClose() -> Bool {
            if approved { return true }
            approved = approveClose()
            return approved
        }
        func attach(to window: NSWindow) {
            guard window.delegate !== self else { return }
            self.window = window
            original = window.delegate
            window.delegate = self
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard original?.windowShouldClose?(sender) ?? true else { return false }
            return requestClose()
        }
        func windowWillClose(_ notification: Notification) {
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
