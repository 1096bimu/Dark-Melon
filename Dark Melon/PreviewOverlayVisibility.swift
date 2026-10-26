import SwiftUI

/// Keeps the approach area active even while the controls themselves are hidden.
struct PreviewOverlayVisibility: ViewModifier {
    @State private var nearby = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .opacity(nearby ? 1 : 0)
            .padding(28)
            .contentShape(Rectangle())
            .onHover { nearby = $0 }
            .padding(-28)
            .animation(.easeInOut(duration: reduceMotion ? 0 : 0.2), value: nearby)
        #else
        content
        #endif
    }
}
