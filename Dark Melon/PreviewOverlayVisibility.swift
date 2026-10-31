import SwiftUI

/// Keeps the approach area active even while the controls themselves are hidden.
struct PreviewOverlayVisibility: ViewModifier {
    @State private var nearby = false
    @State private var visible = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .opacity(visible ? 1 : 0)
            .padding(28)
            .contentShape(Rectangle())
            .onHover { nearby = $0 }
            .padding(-28)
            .task(id: nearby) {
                if nearby { visible = true; return }
                do {
                    try await Task.sleep(for: .seconds(5))
                    try Task.checkCancellation()
                    visible = false
                } catch { }
            }
            .animation(.easeInOut(duration: reduceMotion ? 0 : 0.2), value: visible)
        #else
        content
        #endif
    }
}

/// Shared treatment for floating controls and information inside the preview.
struct PreviewOverlayStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(10)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
    }
}
