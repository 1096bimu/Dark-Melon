import SwiftUI

private struct SliderTrackKey: EnvironmentKey {
    static let defaultValue = AnyShapeStyle(EditorGraphStyle.trackColor)
}
private struct SliderTintKey: EnvironmentKey {
    static let defaultValue = Color.primary
}
private struct SliderTintLevelKey: EnvironmentKey {
    static let defaultValue = 0.85
}
extension EnvironmentValues {
    fileprivate var sliderTintLevel: Double {
        get { self[SliderTintLevelKey.self] }
        set { self[SliderTintLevelKey.self] = newValue }
    }
    fileprivate var sliderTrack: AnyShapeStyle {
        get { self[SliderTrackKey.self] }
        set { self[SliderTrackKey.self] = newValue }
    }
    fileprivate var sliderTint: Color {
        get { self[SliderTintKey.self] }
        set { self[SliderTintKey.self] = newValue }
    }
}
extension View {
    /// Any shape style, including gradients with repeated stops for hard bands.
    func editorSliderTrack(_ style: some ShapeStyle) -> some View {
        environment(\.sliderTrack, AnyShapeStyle(style))
    }
    func editorSliderTint(_ color: Color, level: Double = 0.85) -> some View {
        environment(\.sliderTint, color).environment(\.sliderTintLevel, level)
    }
}

enum EditorSliderTracks {
    // Sixteen samples per cycle; cache the sinusoid so moving Tone only blends colors.
    private static let contrastSamples: [(position: Double, brightness: Double)] = (0...320).map { index in
        let x = Double(index) / 320
        return (x, 0.5 + 0.5 * x * sin(40 * .pi * x))
    }

    static func contrast(tone: Double, white: Double) -> LinearGradient {
        let position = min(1, max(0, tone / max(ToneMapping.minimumRange, white)))
        let waveWeight = 4 * position * (1 - position)
        let stops = contrastSamples.map { sample in
            let ramp = sample.position * (1 - position) + (1 - sample.position) * position
            let brightness = ramp + waveWeight * (sample.brightness - ramp)
            return Gradient.Stop(color: Color(white: brightness), location: sample.position)
        }
        return LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing)
    }
    // Signed amplitude reverses each complementary pair across the neutral center.
    // These tracks are fixed, so generate them once rather than on slider updates.
    static let dyeResponse: [LinearGradient] = (0..<3).map { channel in
        let stops = (0...320).map { index in
            let x = Double(index) / 320
            let wave = (1 - 2 * x) * sin(40 * .pi * x)
            let primary = 0.5 + 0.5 * wave
            let complement = 0.5 - 0.5 * wave
            let color = Color(.sRGB,
                              red: channel == 0 ? primary : complement,
                              green: channel == 1 ? primary : complement,
                              blue: channel == 2 ? primary : complement)
            return Gradient.Stop(color: color, location: x)
        }
        return LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing)
    }
    static let tone = LinearGradient(colors: [.black, .white], startPoint: .leading, endPoint: .trailing)
    static let temperature = LinearGradient(colors: [.blue, Color(white: 0.8), .orange], startPoint: .leading, endPoint: .trailing)
    static let tint = LinearGradient(colors: [.green, Color(white: 0.8), Color(red: 1, green: 0, blue: 1)], startPoint: .leading, endPoint: .trailing)
}

/// A full-width track with no progress fill. Dragging the thumb preserves its
/// grab offset; clicking elsewhere jumps to that position. No scroll gestures.
struct EditorSlider<Value: BinaryFloatingPoint>: View {
    @Binding var value: Value
    let bounds: ClosedRange<Value>
    let step: Value?
    let label: Text
    let onEditingChanged: (Bool) -> Void
    @Environment(\.isEnabled) private var enabled
    @Environment(\.controlResetAction) private var reset
    @Environment(\.sliderTrack) private var track
    @Environment(\.sliderTint) private var tint
    @Environment(\.sliderTintLevel) private var tintLevel
    @GestureState private var dragging = false
    @State private var editing = false
    @State private var dragOrigin: CGFloat?
    @FocusState private var focused: Bool

    init(value: Binding<Value>, in bounds: ClosedRange<Value>, step: Value? = nil,
         onEditingChanged: @escaping (Bool) -> Void = { _ in },
         @ViewBuilder label: () -> Text = { Text("") }) {
        self._value = value; self.bounds = bounds; self.step = step
        self.onEditingChanged = onEditingChanged; self.label = label()
    }

    init(value: Binding<Value>, in bounds: ClosedRange<Value>, step: Value? = nil,
         @ViewBuilder label: () -> Text, onEditingChanged: @escaping (Bool) -> Void) {
        self.init(value: value, in: bounds, step: step, onEditingChanged: onEditingChanged, label: label)
    }

    private var fraction: Double {
        let span = Double(bounds.upperBound - bounds.lowerBound)
        guard span > 0, value.isFinite else { return 0 }
        return min(1, max(0, Double(value - bounds.lowerBound) / span))
    }
    private func set(_ proposed: Value) {
        var next = min(bounds.upperBound, max(bounds.lowerBound, proposed))
        if let step, step > 0 {
            next = bounds.lowerBound + ((next - bounds.lowerBound) / step).rounded() * step
        }
        value = min(bounds.upperBound, max(bounds.lowerBound, next))
    }
    private func finish() {
        dragOrigin = nil
        guard editing else { return }
        editing = false
        onEditingChanged(false)
    }
    private func nudge(_ positive: Bool) {
        guard enabled else { return }
        onEditingChanged(true)
        let delta = step ?? (bounds.upperBound - bounds.lowerBound) / 100
        set(value + (positive ? delta : -delta))
        onEditingChanged(false)
    }

    var body: some View {
        GeometryReader { geometry in
            let inset: CGFloat = 14
            let travel = max(1, geometry.size.width - 2 * inset)
            let thumb = inset + fraction * travel
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                    .frame(height: EditorGraphStyle.trackWidth)
                    .padding(.horizontal, inset)
                EditorGraphHandle(color: tint, isDragging: dragging, tintLevel: tintLevel)
                    .environment(\.controlResetAction, nil)
                    .position(x: thumb, y: geometry.size.height / 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .overlay {
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .updating($dragging) { _, state, _ in if enabled { state = true } }
                        .onChanged { gesture in
                            guard enabled else { return }
                            if !editing {
                                focused = true
                                dragOrigin = abs(gesture.startLocation.x - thumb) <= 14 ? thumb : gesture.startLocation.x
                                editing = true
                                onEditingChanged(true)
                            }
                            let x = (dragOrigin ?? thumb) + gesture.translation.width
                            let position = min(1, max(0, (x - inset) / travel))
                            set(bounds.lowerBound + Value(position) * (bounds.upperBound - bounds.lowerBound))
                        }.onEnded { _ in finish() })
            }
        }
        .frame(height: 28)
        .opacity(enabled ? 1 : 0.4)
        .background {
            // Keep the macOS focus responder behind the pointer gesture surface.
            Color.clear.focusable(enabled, interactions: .edit)
                .focused($focused).focusEffectDisabled().allowsHitTesting(false)
        }
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.primary.opacity(0.45), lineWidth: 1).opacity(focused ? 1 : 0).allowsHitTesting(false))
        .onKeyPress(.leftArrow) { guard enabled else { return .ignored }; nudge(false); return .handled }
        .onKeyPress(.rightArrow) { guard enabled else { return .ignored }; nudge(true); return .handled }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(Double(value).formatted(.number.precision(.fractionLength(2))))
        .accessibilityAdjustableAction { nudge($0 == .increment) }
        .onChange(of: dragging) { _, active in if !active { finish() } }
        .onChange(of: enabled) { _, active in if !active { finish() } }
        .onDisappear { finish() }
        .resetInteraction(reset.map { action in {
            finish()
            onEditingChanged(true)
            action()
            onEditingChanged(false)
        } })
    }
}
