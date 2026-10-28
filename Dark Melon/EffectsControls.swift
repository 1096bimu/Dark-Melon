import SwiftUI

struct EffectsControls: View {
    @Environment(\.resetMapping) private var defaults
    @Environment(\.lockedFilmItems) private var lockedItems
    @Binding var badHDR: BadHDRSettings
    @Binding var dyeMixers: DyeMixers
    var randomizeDye: (Double) -> Void
    @AppStorage("dyeRandomStrength") private var randomStrength = 1.0
    @State private var brewHues: [Double] = []
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

    private func refreshBrewTrack() {
        brewHues = (0..<12).map { _ in Double.random(in: 0..<1) }
    }

    private var brewTrack: LinearGradient {
        var stops = [Gradient.Stop(color: EditorGraphStyle.trackColor, location: 0)]
        for (index, hue) in brewHues.enumerated() {
            let start = 0.15 + 0.85 * Double(index) / Double(brewHues.count)
            let end = 0.15 + 0.85 * Double(index + 1) / Double(brewHues.count)
            let color = Color(hue: hue, saturation: 0.35 + 0.45 * start, brightness: 0.85)
            stops.append(.init(color: color, location: start))
            stops.append(.init(color: color, location: end))
        }
        if brewHues.isEmpty { stops.append(.init(color: EditorGraphStyle.trackColor, location: 1)) }
        return LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Effects").font(.headline)
                Spacer()
                HoldCompareButton(comparing: $comparing)
                    .disabled(dyeMixers.isIdentity && channelContrast.dropFirst().allSatisfy { $0 == channelContrast[0] } && clarity == 0 && hdf == 0 && grain.strength == 0 && vignette.amount == 0 && (!hdrEnabled || halation.inputCurve == 0) && badHDR.strength == 0)
                Button("Reset Effects") {
                    if !lockedItems.contains(.badHDR) { badHDR = defaults.badHDR }
                    if !lockedItems.contains(.dyeResponse) { channelContrast = defaults.channelContrast; dyeMixers = defaults.dyeMixers }
                    if !lockedItems.contains(.grain) { grain = defaults.grain }
                    if !lockedItems.contains(.halation) { halation = defaults.halation }
                    if !lockedItems.contains(.clarity) { clarity = defaults.clarity; radius = defaults.clarityRadius }
                    if !lockedItems.contains(.hdf) { hdf = defaults.hdf; hdfRadius = defaults.hdfRadius }
                    if !lockedItems.contains(.vignette) { vignette = defaults.vignette }
                }
                    .disabled(dyeMixers == defaults.dyeMixers && channelContrast == defaults.channelContrast && clarity == defaults.clarity && radius == defaults.clarityRadius && hdf == defaults.hdf && hdfRadius == defaults.hdfRadius && grain == defaults.grain && halation == defaults.halation && vignette == defaults.vignette && badHDR == defaults.badHDR)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Cross Processing").fontWeight(.medium)
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
                        EditorSlider(value: value, in: -0.2...0.2)
                            .controlReset { channelContrast[channel] = defaults.channelContrast[channel] }
                            .accessibilityLabel(Text(LocalizedStringKey(name)))
                        AdjustmentField(title: LocalizedStringKey(name), value: value, range: -1...1,
                                        digits: 1, scale: 100, unit: "%")
                    }
                }
                HStack {
                    Image(systemName: "laser.burst")
                        .frame(width: 22)
                        .accessibilityHidden(true)
                    EditorSlider(value: $randomStrength, in: 0...3)
                        .editorSliderTrack(brewTrack)
                        .controlReset { randomStrength = 1 }
                        .accessibilityLabel(Text("Randomization strength"))
                    HStack(spacing: 3) {
                        Button {
                            randomizeDye(randomStrength)
                            refreshBrewTrack()
                        } label: {
                            Text("Brew").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .frame(width: 72)
                        // Match the RGB fields' unit column as well as their width.
                        Text("%").hidden().accessibilityHidden(true)
                    }
                    .font(.body.monospacedDigit())
                }
                .help("Sets the range for the next Brew. Zero produces identity matrices; 100% uses the original range; 300% triples it. Existing matrices are unchanged until you brew.")
                DyeMatrixField(mixers: $dyeMixers, rgb: $channelContrast)
            }
            .onAppear { if brewHues.isEmpty { refreshBrewTrack() } }
            .filmLock(.dyeResponse)
            .help("Changes relative film-layer contrast around Tone in log exposure. Equal RGB values have no effect; the SDR and HDR tone curves remain unchanged.")
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Clarity")
                    AdjustmentField(title: "Clarity", value: $clarity, range: AdjustmentLimits.signedStrength, digits: 3, scale: 1, unit: "").filmLock(.clarity)

                }
                HStack {
                    Image(systemName: "dial.medium")
                    EditorSlider(value: $clarity, in: -2...2, label: { Text("Clarity") }).controlReset { clarity = defaults.clarity }.filmLock(.clarity)
                        .labelsHidden()
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Radius")
                    AdjustmentField(title: "Radius", value: Binding(get: { radius / 30 }, set: { radius = $0 * 30 }), range: AdjustmentLimits.radius, digits: 2, scale: 1, unit: "×").filmLock(.clarity)

                }
                HStack {
                    Image(systemName: "circle.dashed")
                    EditorSlider(value: Binding(get: { radius / 30 }, set: { radius = $0 * 30 }), in: 0.5...3, label: { Text("Radius") }).controlReset { radius = defaults.clarityRadius }.filmLock(.clarity)
                        .labelsHidden()
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("HDF")
                    AdjustmentField(title: "HDF", value: $hdf, range: AdjustmentLimits.strength, digits: 3, scale: 1, unit: "").filmLock(.hdf)

                }
                HStack {
                    Image(systemName: "aqi.low")
                    EditorSlider(value: $hdf, in: 0...0.2, label: { Text("HDF") }).controlReset { hdf = defaults.hdf }.filmLock(.hdf)
                        .labelsHidden()
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Radius")
                    AdjustmentField(title: "HDF radius", value: Binding(get: { hdfRadius / 100 }, set: { hdfRadius = $0 * 100 }), range: AdjustmentLimits.radius, digits: 2, scale: 1, unit: "×").filmLock(.hdf)

                }
                HStack {
                    Image(systemName: "circle.dashed")
                    EditorSlider(value: Binding(get: { hdfRadius / 100 }, set: { hdfRadius = $0 * 100 }), in: 0.5...2, label: { Text("HDF radius") }).controlReset { hdfRadius = defaults.hdfRadius }.filmLock(.hdf)
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
                    EditorSlider(value: $halation.inputCurve, in: 0...1, label: { Text("Halation") }).controlReset { halation.inputCurve = defaults.halation.inputCurve }.labelsHidden()
                }
                HStack {
                    Text("Radius")
                    AdjustmentField(title: "Halation radius", value: $halation.radius, range: AdjustmentLimits.radius, digits: 2, scale: 1, unit: "×")

                }
                HStack {
                    Image(systemName: "circle.dashed")
                    EditorSlider(value: $halation.radius, in: 0.5...3, label: { Text("Halation radius") }).controlReset { halation.radius = defaults.halation.radius }.labelsHidden()
                }
                Group {
                HStack {
                    Text("Transmission")
                    AdjustmentField(title: "Transmission", value: $halation.transmission, range: 0...1, digits: 2, scale: 1, unit: "")

                }
                EditorSlider(value: $halation.transmission, in: 0...0.5, label: { Text("Transmission") }).controlReset { halation.transmission = defaults.halation.transmission }.labelsHidden()
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
                    AdjustmentField(title: "Vignette amount", value: $vignette.amount, range: AdjustmentLimits.vignetteStops, digits: 2, scale: 1, unit: "stops").filmLock(.vignette)

                }
                EditorSlider(value: $vignette.amount, in: 0...4, label: { Text("Vignette amount") }).controlReset { vignette.amount = defaults.vignette.amount }.filmLock(.vignette).labelsHidden()
                HStack {
                    Text("Spread")
                    AdjustmentField(title: "Vignette spread", value: $vignette.spread, range: 0...1, digits: 0, scale: 100, unit: "%").filmLock(.vignette)

                }
                EditorSlider(value: $vignette.spread, in: 0...1, label: { Text("Vignette spread") }).controlReset { vignette.spread = defaults.vignette.spread }.filmLock(.vignette).labelsHidden()
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("BadHDR")
                    AdjustmentField(title: "BadHDR", value: $badHDR.strength, range: AdjustmentLimits.signedStrength, digits: 0, scale: 100, unit: "%")
                }
                HStack {
                    Image(systemName: "burn")
                    EditorSlider(value: $badHDR.strength, in: -4...4, label: { Text("BadHDR") }).controlReset { badHDR.strength = defaults.badHDR.strength }.labelsHidden()
                }
                HStack {
                    Text("Radius")
                    AdjustmentField(title: "BadHDR radius", value: $badHDR.radius, range: AdjustmentLimits.radius, digits: 2, unit: "×")
                }
                HStack {
                    Image(systemName: "circle.dashed")
                    EditorSlider(value: $badHDR.radius, in: 0.5...3, label: { Text("BadHDR radius") }).controlReset { badHDR.radius = defaults.badHDR.radius }.labelsHidden()
                }
            }
            .filmLock(.badHDR)
            .help("Uses blurred luminance to reduce highlights before tone mapping while preserving color ratios. Negative strength reverses the effect.")
        }
        .padding(12)
    }
}
