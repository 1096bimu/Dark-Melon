import SwiftUI

struct EffectsControls: View {
    @Binding var clarity: Double
    @Binding var radius: Double
    @Binding var hdf: Double
    @Binding var hdfRadius: Double
    @Binding var grain: FilmGrainSettings
    @Binding var comparing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Effects").font(.headline)
                Spacer()
                HoldCompareButton(comparing: $comparing)
                    .disabled(clarity == 0 && hdf == 0 && grain.strength == 0)
                Button("Reset Effects") { clarity = 0; radius = 30; hdf = 0; hdfRadius = 100; grain = FilmGrainSettings() }
                    .disabled(clarity == 0 && radius == 30 && hdf == 0 && hdfRadius == 100 && grain == FilmGrainSettings())
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Clarity")
                    Text(clarity, format: .number.precision(.fractionLength(3)))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                HStack {
                    Image(systemName: "dial.medium")
                    Slider(value: $clarity, in: -2...2) { Text("Clarity") }
                        .labelsHidden()
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Radius")
                    Text("\(radius / 30, format: .number.precision(.fractionLength(2)))×")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                HStack {
                    Image(systemName: "circle.dashed")
                    Slider(value: Binding(get: { radius / 30 }, set: { radius = $0 * 30 }), in: 0.5...3) { Text("Radius") }
                        .labelsHidden()
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("HDF")
                    Text(hdf, format: .number.precision(.fractionLength(3)))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                HStack {
                    Image(systemName: "aqi.low")
                    Slider(value: $hdf, in: 0...0.2) { Text("HDF") }
                        .labelsHidden()
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Radius")
                    Text("\(hdfRadius / 100, format: .number.precision(.fractionLength(2)))×")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                HStack {
                    Image(systemName: "circle.dashed")
                    Slider(value: Binding(get: { hdfRadius / 100 }, set: { hdfRadius = $0 * 100 }), in: 0.5...2) { Text("HDF radius") }
                        .labelsHidden()
                }
            }
            Divider()
            FilmGrainControls(settings: $grain)
        }
        .padding(12)
    }
}
