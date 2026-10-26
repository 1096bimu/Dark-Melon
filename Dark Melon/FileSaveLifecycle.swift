#if os(macOS)
import SwiftUI
import AppKit

@MainActor final class SaveLifecycleAppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        FileOpenRequests.shared.receive(urls)
    }

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

/// Finder can deliver a file before SwiftUI has attached its first editor window.
@MainActor final class FileOpenRequests {
    static let shared = FileOpenRequests()
    private(set) var pendingURL: URL?
    private var openEditor: (() -> Void)?

    func receive(_ urls: [URL]) {
        guard let url = urls.first(where: \.isFileURL) else { return }
        pendingURL = url
        if !deliver() { openEditor?() }
    }

    func editorReady(openEditor: @escaping () -> Void) {
        self.openEditor = openEditor
        // Avoid changing editor state during NSViewRepresentable attachment.
        Task { @MainActor in _ = deliver() }
    }

    @discardableResult
    private func deliver() -> Bool {
        guard let url = pendingURL else { return true }
        let windows = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 } + NSApp.orderedWindows
        guard let window = windows.first(where: { $0.delegate is FileSaveLifecycle.Coordinator }),
              let editor = window.delegate as? FileSaveLifecycle.Coordinator else { return false }
        pendingURL = nil
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        editor.openFile(url)
        return true
    }
}

/// Preserve SwiftUI's window delegate while gating closure on an explicit pending-edit decision.
struct FileSaveLifecycle: NSViewRepresentable {
    @Environment(\.openWindow) private var openWindow
    let approveClose: () -> Bool
    let openFile: (URL) -> Void
    func makeCoordinator() -> Coordinator {
        Coordinator(approveClose: approveClose, openFile: openFile, openEditor: { openWindow(id: "editor") })
    }
    func makeNSView(context: Context) -> Host {
        let view = Host()
        view.coordinator = context.coordinator
        return view
    }
    func updateNSView(_ view: Host, context: Context) {
        context.coordinator.approveClose = approveClose
        context.coordinator.openFile = openFile
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
        var openFile: (URL) -> Void
        private let openEditor: () -> Void
        private var approved = false
        private weak var original: (any NSWindowDelegate)?
        private weak var window: NSWindow?
        init(approveClose: @escaping () -> Bool, openFile: @escaping (URL) -> Void,
             openEditor: @escaping () -> Void) {
            self.approveClose = approveClose
            self.openFile = openFile
            self.openEditor = openEditor
        }
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
            FileOpenRequests.shared.editorReady(openEditor: openEditor)
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
