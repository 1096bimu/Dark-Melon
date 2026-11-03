import AppKit
import SwiftUI
import Observation
@testable import Dark_Melon

@Observable @MainActor private final class BrowserClickState {
    var browser = true
    var right = true
    var previewClicks = 0
    var browserClicks = 0
    var pillClicks = 0
    var editClicks = 0
}

private struct ClickSurface: NSViewRepresentable {
    var clicked: () -> Void
    func makeNSView(context: Context) -> Surface { Surface() }
    func updateNSView(_ view: Surface, context: Context) { view.clicked = clicked }
    final class Surface: NSView {
        var clicked: () -> Void = {}
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { clicked() }
    }
}

private struct BrowserClickRoot: View {
    let state: BrowserClickState
    var body: some View {
        GlassEditorShell(browserVisible: state.browser, panelVisible: state.right,
            current: nil, resolution: .zero, fileSize: nil,
            dismissBrowser: { state.browser = false }) {
                ClickSurface { state.previewClicks += 1 }
            } browser: {
                ClickSurface { state.browserClicks += 1 }
            } controls: {
                ClickSurface { state.editClicks += 1 }
            } leftToolbar: {
                ClickSurface { state.pillClicks += 1 }.frame(width: 72, height: 28)
            } toolbar: { Text("Center") }
              rightToolbar: { Text("Right") }
    }
}

@main struct FloatingBrowserDismissalChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        Task { @MainActor in
            do { try await runChecks() }
            catch { fatalError("Click-away checks failed: \(error)") }
            fflush(stdout)
            app.terminate(nil)
        }
        app.run()
    }

    @MainActor static func runChecks() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let state = BrowserClickState()
        let host = NSHostingView(rootView: BrowserClickRoot(state: state))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(100))

        func click(x: CGFloat, y: CGFloat) async throws {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: 600 - y),
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1)!
                app.postEvent(event, atStart: false)
            }
            while let event = app.nextEvent(matching: [.leftMouseDown, .leftMouseUp],
                until: Date(timeIntervalSinceNow: 0.02), inMode: .default, dequeue: true) {
                app.sendEvent(event)
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        try await click(x: 100, y: 180)
        precondition(state.browser && state.browserClicks == 1, "Inside browser click dismissed or was swallowed")
        try await click(x: 202, y: 30)
        precondition(state.browser && state.pillClicks == 1, "Left pill click dismissed or was swallowed")
        try await click(x: 600, y: 200)
        precondition(!state.browser && state.previewClicks == 1, "Preview click must dismiss and still reach the preview")
        state.browser = true
        try await Task.sleep(for: .milliseconds(100))
        try await click(x: 1100, y: 180)
        precondition(!state.browser && state.editClicks == 1, "Edit-panel click must dismiss without being swallowed")
        state.browser = true
        state.right = false
        try await Task.sleep(for: .milliseconds(100))
        try await click(x: 600, y: 200)
        precondition(state.browser, "Nonfloating browser should stay open")
        state.right = true
        try await Task.sleep(for: .milliseconds(100))
        try await click(x: 100, y: 54)
        precondition(!state.browser, "Gap between the pill and panel is outside both protected regions")
        window.close()
        print("PASS: protected browser/pill clicks, preview and edit click-through, floating-only dismissal, and outside gap")
    }
}
