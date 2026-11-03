import SwiftUI

/// A switch using the same thumb, rim and disabled treatment as EditorSlider.
struct EditorToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        EditorToggleBody(configuration: configuration)
    }
}

private struct EditorToggleBody: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool

    var body: some View {
        Button {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.18)) {
                configuration.isOn.toggle()
            }
        } label: {
            HStack(spacing: 16) {
                configuration.label.foregroundStyle(.primary)
                Spacer(minLength: 0)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(configuration.isOn ? Color.accentColor : EditorGraphStyle.trackColor)
                        .frame(width: 44, height: 26)
                    EditorGraphHandle(color: .white, tintLevel: 0)
                        .environment(\.controlResetAction, nil)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .frame(width: 44, height: 28)
                .overlay {
                    Capsule().stroke(.primary.opacity(0.45), lineWidth: 1)
                        .padding(-2)
                        .opacity(focused ? 1 : 0)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .focusEffectDisabled()
        .disabled(!enabled)
        .modifier(DisabledControlAppearance())
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch)
        }
    }
}
