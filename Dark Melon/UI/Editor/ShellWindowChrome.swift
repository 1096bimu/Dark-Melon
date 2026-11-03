import SwiftUI
#if os(macOS)
import AppKit
#endif

struct ShellWindowChrome: ViewModifier {
    @AppStorage("glassEffectsEnabled") private var glassEffects = true
    @AppStorage(PreviewBackground.preferenceKey) private var backgroundChoice = ""
    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .ignoresSafeArea(.container, edges: .top)
            .background {
                let background = PreviewBackground.resolve(backgroundChoice, glassEffects: glassEffects)
                if let level = background.greyLevel {
                    Color(white: level).ignoresSafeArea()
                } else {
                    WindowBackdrop().ignoresSafeArea()
                }
            }
            .preferredColorScheme(.dark)
            .background(WindowChromeBridge().frame(width: 0, height: 0))
        #else
        content
        #endif
    }
}

#if os(macOS)
private struct WindowChromeBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> ChromeView { ChromeView() }
    func updateNSView(_ view: ChromeView, context: Context) {
        view.apply()
        // SwiftUI may install/update its toolbar after this representable updates.
        DispatchQueue.main.async { [weak view] in view?.apply() }
    }
    static func dismantleNSView(_ view: ChromeView, coordinator: ()) { view.restore() }

    final class ChromeView: NSView {
        private weak var observed: NSWindow?
        private var original: (NSWindow.TitleVisibility, Bool, Bool, Bool)?
        private var tokens: [NSObjectProtocol] = []
        private var originalToolbar: NSToolbar?
        private var separator: NSTitlebarSeparatorStyle = .automatic
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if observed !== window {
                restore()
                observed = window
                if let window {
                    originalToolbar = window.toolbar
                    separator = window.titlebarSeparatorStyle
                    original = (window.titleVisibility, window.titlebarAppearsTransparent, window.styleMask.contains(.fullSizeContentView), window.toolbar?.isVisible ?? false)
                    for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                        tokens.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                            MainActor.assumeIsolated { self?.apply() }
                        })
                    }
                }
            }
            apply()
        }
        func apply() {
            guard let window = observed else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            // Toolbars belong to the shell rather than the native title bar.
            if let toolbar = window.toolbar { originalToolbar = toolbar; window.toolbar = nil }
            window.styleMask.insert(.fullSizeContentView)
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                if let control = window.standardWindowButton(button) {
                    control.isHidden = !window.isKeyWindow
                    control.alphaValue = 1
                }
            }
        }
        func restore() {
            if let window = observed, let original {
                window.titleVisibility = original.0
                window.titlebarAppearsTransparent = original.1
                window.titlebarSeparatorStyle = separator
                window.toolbar = originalToolbar
                window.toolbar?.isVisible = original.3
                if !original.2 { window.styleMask.remove(.fullSizeContentView) }
                for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                    window.standardWindowButton(button)?.isHidden = false
                }
            }
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens.removeAll()
            observed = nil
            original = nil
            originalToolbar = nil
        }
    }
}

/// Behind-window material gives every uncovered part of the editor the same backdrop.
private struct WindowBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

#endif
