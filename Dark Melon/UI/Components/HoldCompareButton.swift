import SwiftUI

struct HoldCompareButton: View {
    @Binding var comparing: Bool
    var title: LocalizedStringKey = "Compare"
    var help: LocalizedStringKey = "Hold to preview without this panel’s effects. Release to restore them."

    var body: some View {
        Button(title) {}
            .buttonStyle(HoldStyle(comparing: $comparing))
            .help(help)
            .onDisappear { comparing = false }
    }

    private struct HoldStyle: ButtonStyle {
        @Binding var comparing: Bool
        @Environment(\.isEnabled) private var isEnabled

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(configuration.isPressed ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.1),
                            in: RoundedRectangle(cornerRadius: 5))
                .opacity(isEnabled ? 1 : 0.4)
                .onChange(of: configuration.isPressed) { _, pressed in comparing = pressed && isEnabled }
                .onChange(of: isEnabled) { _, enabled in if !enabled { comparing = false } }
        }
    }
}
