import SwiftUI

struct EffectsControls: View {
    @Binding var clarity: Double
    @Binding var radius: Double
    @Binding var hdf: Double
    @Binding var hdfRadius: Double
    @Binding var grain: FilmGrainSettings
    @Binding var halation: HalationSettings
    @Binding var vignette: VignetteSettings
    let hdrEnabled: Bool
    @Binding var comparing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Effects").font(.headline)
                Spacer()
                HoldCompareButton(comparing: $comparing)
                    .disabled(clarity == 0 && hdf == 0 && grain.strength == 0 && vignette.amount == 0 && (!hdrEnabled || halation.inputCurve == 0))
                Button("Reset Effects") { clarity = 0; radius = 30; hdf = 0; hdfRadius = 100; grain = FilmGrainSettings(); halation = HalationSettings(); vignette = VignetteSettings() }
                    .disabled(clarity == 0 && radius == 30 && hdf == 0 && hdfRadius == 100 && grain == FilmGrainSettings() && halation == HalationSettings() && vignette == VignetteSettings())
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Clarity")
                    AdjustmentField(title: "Clarity", value: $clarity, range: -2...2, digits: 3, scale: 1, unit: "")

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
                    AdjustmentField(title: "Radius", value: Binding(get: { radius / 30 }, set: { radius = $0 * 30 }), range: 0.5...3, digits: 2, scale: 1, unit: "×")

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
                    AdjustmentField(title: "HDF", value: $hdf, range: 0...0.2, digits: 3, scale: 1, unit: "")

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
                    AdjustmentField(title: "HDF radius", value: Binding(get: { hdfRadius / 100 }, set: { hdfRadius = $0 * 100 }), range: 0.5...2, digits: 2, scale: 1, unit: "×")

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
                    AdjustmentField(title: "Halation", value: $halation.inputCurve, range: 0...1, digits: 3, scale: 1, unit: "")

                }
                HStack {
                    Image(systemName: "sun.haze")
                    Slider(value: $halation.inputCurve, in: 0...1) { Text("Halation") }.labelsHidden()
                }
                HStack {
                    Text("Radius")
                    AdjustmentField(title: "Halation radius", value: $halation.radius, range: 0.5...3, digits: 2, scale: 1, unit: "×")

                }
                HStack {
                    Image(systemName: "circle.dashed")
                    Slider(value: $halation.radius, in: 0.5...3) { Text("Halation radius") }.labelsHidden()
                }
                HStack {
                    Text("Transmission")
                    AdjustmentField(title: "Transmission", value: $halation.transmission, range: 0...0.5, digits: 2, scale: 1, unit: "")

                }
                Slider(value: $halation.transmission, in: 0...0.5) { Text("Transmission") }.labelsHidden()
            }
            .disabled(!hdrEnabled)
            if !hdrEnabled {
                Text("Enable HDR Gain to use Halation.").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Vignette").font(.headline)
                HStack {
                    Text("Amount")
                    AdjustmentField(title: "Vignette amount", value: $vignette.amount, range: 0...4, digits: 2, scale: 1, unit: "stops")

                }
                Slider(value: $vignette.amount, in: 0...4) { Text("Vignette amount") }.labelsHidden()
                HStack {
                    Text("Spread")
                    AdjustmentField(title: "Vignette spread", value: $vignette.spread, range: 0...1, digits: 0, scale: 100, unit: "%")

                }
                Slider(value: $vignette.spread, in: 0...1) { Text("Vignette spread") }.labelsHidden()
            }
        }
        .padding(12)
    }
}
