import SwiftUI

struct FilmGrainControls: View {
    @Environment(\.resetMapping) private var defaults
    @Binding var settings: FilmGrainSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Film Grain").font(.headline)
                AdjustmentField(title: "Film Grain", value: $settings.strength, range: AdjustmentLimits.strength, digits: 2, scale: 1)
            }
            HStack {
                Image(systemName: "circle.bottomrighthalf.pattern.checkered").frame(width: 22).accessibilityHidden(true)
                EditorSlider(value: $settings.strength, in: 0...2.5, label: { Text("Film Grain") })
                    .controlReset { settings.strength = defaults.grain.strength }.labelsHidden()
            }
            Picker("Grain output", selection: $settings.output) {
                Text("Digital").tag(FilmGrainSettings.Output.additive)
                Text("Analogue").tag(FilmGrainSettings.Output.filmDensity)
            }
            .pickerStyle(.segmented).labelsHidden()
            .controlReset { settings.output = defaults.grain.output }
            .help("Analogue adds fog and compresses highlights, even at zero grain strength.")
            if settings.output == .additive {
                HStack {
                    Text("Offset")
                    AdjustmentField(title: "Offset", value: $settings.offset, range: -1...1, digits: 2, scale: 1)
                }
                HStack {
                    Image(systemName: "plusminus").frame(width: 22).accessibilityHidden(true)
                    EditorSlider(value: $settings.offset, in: -1...1, label: { Text("Offset") })
                        .controlReset { settings.offset = defaults.grain.offset }.labelsHidden()
                }
            }
            HStack {
                Text("Color Scale")
                AdjustmentField(title: "Color Scale", value: $settings.colorScale, range: 0...1, digits: 0, scale: 100, unit: "%")
            }
            HStack {
                Image(systemName: "camera.filters").frame(width: 22).accessibilityHidden(true)
                EditorSlider(value: $settings.colorScale, in: 0...1, label: { Text("Color Scale") })
                    .controlReset { settings.colorScale = defaults.grain.colorScale }.labelsHidden()
            }
            HStack {
                Text("Size")
                AdjustmentField(title: "Size", value: $settings.size, range: AdjustmentLimits.grainSize, digits: 2, scale: 1, unit: "×")
            }
            HStack {
                Image(systemName: "circle.dashed").frame(width: 22).accessibilityHidden(true)
                EditorSlider(value: $settings.size, in: AdjustmentLimits.grainSize, label: { Text("Grain size") })
                    .controlReset { settings.size = defaults.grain.size }.labelsHidden()
            }
        }
    }
}
