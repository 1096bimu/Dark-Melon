import SwiftUI

struct ChromaticAberrationControls: View {
    @Environment(\.resetMapping) private var defaults
    @Binding var settings: ChromaticAberration
    var sampleEdge: (() -> Void)? = nil
    var sampling = false
    var drawingEdge = false

    var body: some View {
        EditorSection(title: "Chromatic Aberration") {
            Button("Reset") { settings = defaults.chromaticAberration }
                .disabled(settings == defaults.chromaticAberration)
        } content: {
            VStack(spacing: 12) {
                if let sampleEdge {
                    HStack {
                        Button(sampling ? "Cancel" : "Sample Edge", systemImage: "scope", action: sampleEdge)
                        Spacer()
                    }
                }
                if drawingEdge {
                    Text("Draw across a high-contrast edge. The line follows a radius from the image center.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ChromaticAberrationSliders(settings: $settings)
            }
            .help("Spatially scales red and blue around the image center, keeping green fixed. Positive values enlarge the channel. Changes rebuild the source before dust correction.")
        }
    }
}

struct ChromaticAberrationSliders: View {
    @Environment(\.resetMapping) private var defaults
    @Binding var settings: ChromaticAberration
    var body: some View {
        VStack(spacing: 12) {
            channel("Red", value: $settings.red, color: .red, reset: defaults.chromaticAberration.red)
            channel("Blue", value: $settings.blue, color: .blue, reset: defaults.chromaticAberration.blue)
        }
    }

    private func channel(_ title: LocalizedStringKey, value: Binding<Double>, color: Color, reset: Double) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(title)
                AdjustmentField(title: title, value: value, range: ChromaticAberration.range, digits: 3, scale: 1, unit: "%")
            }
            HStack {
                Circle().fill(color).frame(width: 12, height: 12).frame(width: 22).accessibilityHidden(true)
                EditorSlider(value: value, in: -1...1, label: { Text(title) })
                    .controlReset { value.wrappedValue = reset }.labelsHidden()
            }
        }
    }
}
