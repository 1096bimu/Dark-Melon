#if os(macOS)
import SwiftUI
import AppKit

/// Capability-only warning, independent of brightness-dependent available headroom.
struct HDRCapabilityNotice: ViewModifier {
    let enabled: Bool
    @State private var supportsEDR: Bool?
    func body(content: Content) -> some View {
        content.background(HDRCapabilityProbe(value: $supportsEDR))
            .overlay(alignment: .bottom) {
                if enabled, supportsEDR == false {
                    Label("This display does not support HDR", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.white)
                        .modifier(PreviewOverlayStyle()).padding(12)
                }
            }
    }
}

struct EditorStatusPill: View {
    let hdrWarning: Bool
    var queue = ExportQueue.shared
    @State private var showingQueue = false

    private var showsQueue: Bool { queue.showsStatus || showingQueue }

    var body: some View {
        if hdrWarning || showsQueue {
            HStack(spacing: 0) {
                HDRDisplayWarningButton(enabled: hdrWarning)
                if showsQueue {
                    Button("Exports", systemImage: queue.symbol) { showingQueue.toggle() }
                        .labelStyle(.iconOnly)
                        .frame(width: 36, height: 36)
                        .buttonStyle(.plain)
                        .popover(isPresented: $showingQueue) {
                            ExportQueueView(queue: queue)
                                .onAppear { queue.markStatusViewed() }
                        }
                }
            }
            .modifier(ShellPill())
            .onChange(of: queue.jobs.last?.id) { _, _ in
                if showingQueue { queue.markStatusViewed() }
            }
        }
    }
}

private struct HDRDisplayWarningButton: View {
    let enabled: Bool
    @State private var showingExplanation = false
    var body: some View {
        Group {
            if enabled {
                Button { showingExplanation.toggle() } label: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange).frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("This display does not support HDR")
                .help("HDR is enabled, but this display has no EDR capability.")
                .popover(isPresented: $showingExplanation) {
                    Text("HDR is enabled, but this display has no EDR capability. HDR brightness cannot be shown on this display.")
                        .font(.callout).padding(16).frame(width: 280)
                }
                .onDisappear { showingExplanation = false }
            }
        }
    }
}

struct HDRCapabilityProbe: NSViewRepresentable {
    @Binding var value: Bool?
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        view.report = { value = $0 }
        view.scheduleUpdate()
    }
    final class Probe: NSView {
        var report: ((Bool?) -> Void)?
        private var last: Bool?
        override init(frame: NSRect) {
            super.init(frame: frame)
            NotificationCenter.default.addObserver(self, selector: #selector(scheduleUpdate), name: NSApplication.didChangeScreenParametersNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(screenChanged(_:)), name: NSWindow.didChangeScreenNotification, object: nil)
        }
        convenience init() { self.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        deinit { NotificationCenter.default.removeObserver(self) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleUpdate() }
        @objc private func screenChanged(_ notification: Notification) {
            if notification.object as? NSWindow === window { scheduleUpdate() }
        }
        @objc func scheduleUpdate() {
            // Publish outside SwiftUI's representable update transaction.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let value = self.window?.screen.map { $0.maximumPotentialExtendedDynamicRangeColorComponentValue > 1 }
                if value != self.last { self.last = value; self.report?(value) }
            }
        }
    }
}
#endif
