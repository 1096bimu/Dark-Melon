import SwiftUI

struct EffectsControls: View {
    @Environment(\.resetMapping) private var defaults
    @Environment(\.lockedFilmItems) private var lockedItems
    @Binding var badHDR: BadHDRSettings
    @Binding var channelContrast: [Double]
    @Binding var clarity: Double
    @Binding var radius: Double
    @Binding var hdf: Double
    @Binding var hdfRadius: Double
    @Binding var grain: FilmGrainSettings
    @Binding var halation: HalationSettings
    @Binding var vignette: VignetteSettings
    let hdrEnabled: Bool
    var monochrome = false
    @Binding var comparing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Effects").font(.headline)
                Spacer()
                HoldCompareButton(comparing: $comparing)
                    .disabled(channelContrast.dropFirst().allSatisfy { $0 == channelContrast[0] } && clarity == 0 && hdf == 0 && grain.strength == 0 && vignette.amount == 0 && (!hdrEnabled || halation.inputCurve == 0) && badHDR.strength == 0)
                Button("Reset Effects") {
                    if !lockedItems.contains(.badHDR) { badHDR = defaults.badHDR }
                    if !lockedItems.contains(.dyeResponse) { channelContrast = defaults.channelContrast }
                    if !lockedItems.contains(.grain) { grain = defaults.grain }
                    if !lockedItems.contains(.halation) { halation = defaults.halation }
                    if !lockedItems.contains(.clarity) { clarity = defaults.clarity; radius = defaults.clarityRadius }
                    if !lockedItems.contains(.hdf) { hdf = defaults.hdf; hdfRadius = defaults.hdfRadius }
                    if !lockedItems.contains(.vignette) { vignette = defaults.vignette }
                }
                    .disabled(channelContrast == defaults.channelContrast && clarity == defaults.clarity && radius == defaults.clarityRadius && hdf == defaults.hdf && hdfRadius == defaults.hdfRadius && grain == defaults.grain && halation == defaults.halation && vignette == defaults.vignette && badHDR == defaults.badHDR)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Dye Response").fontWeight(.medium)
                ForEach(0..<3, id: \.self) { channel in
                    let name = ["Red", "Green", "Blue"][channel]
                    let value = Binding<Double>(get: { channelContrast[channel] }, set: {
                        channelContrast[channel] = $0
                    })
                    HStack {
                        Image(systemName: "circle.lefthalf.striped.horizontal")
                            .foregroundStyle([Color.red, .green, .blue][channel])
                            .frame(width: 22)
                            .accessibilityHidden(true)
                        Slider(value: value, in: -0.2...0.2)
                            .accessibilityLabel(Text(LocalizedStringKey(name)))
                        AdjustmentField(title: LocalizedStringKey(name), value: value, range: -0.2...0.2,
                                        digits: 1, scale: 100, unit: "%")
                    }
                }
            }
            .filmLock(.dyeResponse)
            .help("Changes relative RGB contrast in the tone map. The shared average is ignored, so equal values have no effect.")
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Clarity")
                    AdjustmentField(title: "Clarity", value: $clarity, range: -2...2, digits: 3, scale: 1, unit: "").filmLock(.clarity)

                }
                HStack {
                    Image(systemName: "dial.medium")
                    Slider(value: $clarity, in: -2...2) { Text("Clarity") }.filmLock(.clarity)
                        .labelsHidden()
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Radius")
                    AdjustmentField(title: "Radius", value: Binding(get: { radius / 30 }, set: { radius = $0 * 30 }), range: 0.5...3, digits: 2, scale: 1, unit: "×").filmLock(.clarity)

                }
                HStack {
                    Image(systemName: "circle.dashed")
                    Slider(value: Binding(get: { radius / 30 }, set: { radius = $0 * 30 }), in: 0.5...3) { Text("Radius") }.filmLock(.clarity)
                        .labelsHidden()
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("HDF")
                    AdjustmentField(title: "HDF", value: $hdf, range: 0...0.2, digits: 3, scale: 1, unit: "").filmLock(.hdf)

                }
                HStack {
                    Image(systemName: "aqi.low")
                    Slider(value: $hdf, in: 0...0.2) { Text("HDF") }.filmLock(.hdf)
                        .labelsHidden()
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Radius")
                    AdjustmentField(title: "HDF radius", value: Binding(get: { hdfRadius / 100 }, set: { hdfRadius = $0 * 100 }), range: 0.5...2, digits: 2, scale: 1, unit: "×").filmLock(.hdf)

                }
                HStack {
                    Image(systemName: "circle.dashed")
                    Slider(value: Binding(get: { hdfRadius / 100 }, set: { hdfRadius = $0 * 100 }), in: 0.5...2) { Text("HDF radius") }.filmLock(.hdf)
                        .labelsHidden()
                }
            }
            Divider()
            FilmGrainControls(settings: $grain).filmLock(.grain)
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
                Group {
                HStack {
                    Text("Transmission")
                    AdjustmentField(title: "Transmission", value: $halation.transmission, range: 0...0.5, digits: 2, scale: 1, unit: "")

                }
                Slider(value: $halation.transmission, in: 0...0.5) { Text("Transmission") }.labelsHidden()
                }.disabled(monochrome)
            }
            .disabled(!hdrEnabled).filmLock(.halation)
            if !hdrEnabled {
                Text("Enable HDR Gain to use Halation.").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Vignette").font(.headline)
                HStack {
                    Text("Amount")
                    AdjustmentField(title: "Vignette amount", value: $vignette.amount, range: 0...4, digits: 2, scale: 1, unit: "stops").filmLock(.vignette)

                }
                Slider(value: $vignette.amount, in: 0...4) { Text("Vignette amount") }.filmLock(.vignette).labelsHidden()
                HStack {
                    Text("Spread")
                    AdjustmentField(title: "Vignette spread", value: $vignette.spread, range: 0...1, digits: 0, scale: 100, unit: "%").filmLock(.vignette)

                }
                Slider(value: $vignette.spread, in: 0...1) { Text("Vignette spread") }.filmLock(.vignette).labelsHidden()
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("BadHDR")
                    AdjustmentField(title: "BadHDR", value: $badHDR.strength, range: -4...4, digits: 0, scale: 100, unit: "%")
                }
                HStack {
                    Image(systemName: "burn")
                    Slider(value: $badHDR.strength, in: -4...4) { Text("BadHDR") }.labelsHidden()
                }
                HStack {
                    Text("Radius")
                    AdjustmentField(title: "BadHDR radius", value: $badHDR.radius, range: 0.5...3, digits: 2, unit: "×")
                }
                HStack {
                    Image(systemName: "circle.dashed")
                    Slider(value: $badHDR.radius, in: 0.5...3) { Text("BadHDR radius") }.labelsHidden()
                }
            }
            .filmLock(.badHDR)
            .help("Uses blurred luminance to reduce highlights before tone mapping while preserving color ratios. Negative strength reverses the effect.")
        }
        .padding(12)
    }
}
