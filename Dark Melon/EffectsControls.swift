import SwiftUI

struct EffectsControls: View {
    @Binding var clarity: Double
    @Binding var radius: Double
    @Binding var hdf: Double
    @Binding var hdfRadius: Double
    @Binding var grain: FilmGrainSettings
    @Binding var halation: HalationSettings
    let hdrEnabled: Bool
    @Binding var comparing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Effects").font(.headline)
                Spacer()
                HoldCompareButton(comparing: $comparing)
                    .disabled(clarity == 0 && hdf == 0 && grain.strength == 0 && (!hdrEnabled || halation.inputCurve == 0))
                Button("Reset Effects") { clarity = 0; radius = 30; hdf = 0; hdfRadius = 100; grain = FilmGrainSettings(); halation = HalationSettings() }
                    .disabled(clarity == 0 && radius == 30 && hdf == 0 && hdfRadius == 100 && grain == FilmGrainSettings() && halation == HalationSettings())
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
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Halation")
                    Text(halation.inputCurve, format: .number.precision(.fractionLength(3)))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                HStack {
                    Image(systemName: "sun.haze")
                    Slider(value: $halation.inputCurve, in: 0...1) { Text("Halation") }.labelsHidden()
                }
                HStack {
                    Text("Radius")
                    Text("\(halation.radius, format: .number.precision(.fractionLength(2)))×")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                HStack {
                    Image(systemName: "circle.dashed")
                    Slider(value: $halation.radius, in: 0.5...3) { Text("Halation radius") }.labelsHidden()
                }
                HStack {
                    Text("Transmission")
                    Text(halation.transmission, format: .number.precision(.fractionLength(2)))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: $halation.transmission, in: 0...0.5) { Text("Transmission") }.labelsHidden()
            }
            .disabled(!hdrEnabled)
            if !hdrEnabled {
                Text("Enable HDR Gain to use Halation.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }
}
