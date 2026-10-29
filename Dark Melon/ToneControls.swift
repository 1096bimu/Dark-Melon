import SwiftUI

struct HistogramPoints: View {
    @Environment(\.resetMapping) private var defaults
    @Binding var mapping: ToneMapping
    var inputMaximum = 1.0
    var onWhitePointEditingChanged: (Bool) -> Void = { _ in }
    @State private var dragging = false

    var body: some View {
        GeometryReader { geometry in
            let x = min(geometry.size.width - 1, max(1, geometry.size.width * mapping.white / inputMaximum))
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                }.stroke(.black, lineWidth: 4)
                Path { path in
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                }.stroke(.white, lineWidth: 2)
                Text("W")
                    .font(.caption2.bold()).foregroundStyle(.black).padding(4)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 3))
                    .resetInteraction { update(defaults.white) }
                    .position(x: min(geometry.size.width - 10, max(10, x)), y: 32)
                    .accessibilityLabel("White point")
                    .accessibilityValue(mapping.white.formatted(.number.precision(.fractionLength(4))))
                    .accessibilityAdjustableAction { direction in
                        update(mapping.white + (direction == .increment ? 0.005 : -0.005))
                    }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                if !dragging { dragging = true; onWhitePointEditingChanged(true) }
                update(value.location.x / max(1, geometry.size.width) * inputMaximum)
            }.onEnded { _ in
                onWhitePointEditingChanged(false)
                dragging = false
            })
            .onDisappear { onWhitePointEditingChanged(false) }
        }
    }

    private func update(_ value: Double) {
        mapping.white = min(1, max(ToneMapping.minimumRange, value))
        mapping.tonePosition = min(mapping.tonePosition, mapping.white)
        mapping.setAutomaticHDRTarget()
    }
}

/// A shifted logarithm keeps zero reachable while spreading out low luminances.
nonisolated enum ToneSliderScale {
    private static let knee = 0.001
    private static let span = log1p(1 / knee)

    static func position(for tone: Double) -> Double {
        1 - log1p(tone.clamped(to: 0...1) / knee) / span
    }

    static func tone(at position: Double) -> Double {
        (knee * expm1((1 - position.clamped(to: 0...1)) * span)).clamped(to: 0...1)
    }
}

struct SlopeEditor: View {
    @Environment(\.resetMapping) private var defaults
    @AppStorage("showContrastDistribution") private var showContrastDistribution = true
    @Binding var mapping: ToneMapping
    var sourceISO: Double? = nil
    var rawExposure = 0.0

    var onToneChanged: () -> Void = {}
    var onContrastChanged: () -> Void = {}
    var onISOAdjustment: () -> Void = {}
    var onHDRGainAdjustment: () -> Void = {}
    var onToneEditingChanged: (Bool) -> Void = { _ in }
    var onISOEditingChanged: (Bool) -> Void = { _ in }
    @State private var showLowContrastTip = false

    private var isoExposure: Binding<Double> {
        Binding(get: { ToneISOProxy.exposure(white: mapping.white).clamped(to: ToneISOProxy.range) }, set: { ev in
            mapping = ToneISOProxy.applying(exposure: ev, to: mapping)
            onToneChanged()
            onISOAdjustment()
        })
    }

    private var isoValue: Binding<Double> {
        Binding(get: {
            ToneISOProxy.displayValue(white: mapping.white, sourceISO: sourceISO, rawExposure: rawExposure)
        }, set: { value in
            isoExposure.wrappedValue = ToneISOProxy.adjustment(displayValue: value, sourceISO: sourceISO, rawExposure: rawExposure)
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("ISO")
                    ControlInfo(.iso)
                    AdjustmentField(title: "ISO", value: isoValue,
                        range: ToneISOProxy.displayRange(sourceISO: sourceISO, rawExposure: rawExposure),
                        digits: sourceISO == nil ? 2 : 0, unit: sourceISO == nil ? "EV" : "",
                        commit: { onISOEditingChanged(false) })
                }
                HStack {
                    Image(systemName: "slider.horizontal.below.sun.min").frame(width: 22).accessibilityHidden(true)
                    EditorSlider(value: isoExposure, in: ToneISOProxy.range, onEditingChanged: onISOEditingChanged, label: { Text("ISO") })
                        .editorSliderTicks([0, 1, 2, 3, 4, 5])
                        .controlReset { isoExposure.wrappedValue = ToneISOProxy.exposure(white: defaults.white) }
                        .labelsHidden()
                }
            }
            .filmLock(.tone)
            .filmLock(.whitePoint)
            .help(ControlInfo.Topic.iso.explanation)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Tone")
                    ControlInfo(.tone)
                    AdjustmentField(title: "Tone", value: Binding(get: { mapping.tonePosition }, set: {
                        mapping.tonePosition=min($0, mapping.white); mapping.setAutomaticHDRTarget(); onToneChanged()
                    }), range: 0...mapping.white, digits: 3, commit: { onToneEditingChanged(false) })
                    Spacer()
                }
                HStack {
                    Image(systemName: "swirl.circle.righthalf.filled")
                        .frame(width: 22).accessibilityHidden(true)
                EditorSlider(value: Binding(get: { ToneSliderScale.position(for: min(mapping.tonePosition, mapping.white)) },
                                      set: {
                                          let tone = min(ToneSliderScale.tone(at: $0), mapping.white)
                                          if mapping.tonePosition != tone { onToneChanged() }
                                          mapping.tonePosition = tone
                                          mapping.setAutomaticHDRTarget()
                                          showLowContrastTip = abs(mapping.concentration) <= 0.1
                                      }),
                       in: ToneSliderScale.position(for: mapping.white)...1) {
                    Text("Tone")
                } onEditingChanged: { editing in
                    onToneEditingChanged(editing)
                }
                        .controlReset { mapping.tonePosition = min(mapping.white, defaults.tonePosition); mapping.setAutomaticHDRTarget() }
                        .editorSliderTrack(EditorSliderTracks.tone)
                        .labelsHidden()
                        .accessibilityValue(mapping.tonePosition.formatted(.number.precision(.fractionLength(3))))
                }
                if showLowContrastTip {
                    Label("Tone adjustment is ineffective at low contrast.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .filmLock(.tone)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Contrast")
                    ControlInfo(.contrast)
                    AdjustmentField(title: "Contrast", value: Binding(get: { mapping.concentration }, set: {
                        mapping.concentration=$0; mapping.setAutomaticHDRTarget(); onContrastChanged()
                    }), range: -1...1, digits: 0, scale: 100, unit: "%")
                }
                HStack {
                    Image(systemName: "circle.lefthalf.striped.horizontal")
                        .frame(width: 22).accessibilityHidden(true)
                    EditorSlider(value: Binding(get: { mapping.concentration },
                                          set: {
                                              if mapping.concentration != $0 { onContrastChanged() }
                                              mapping.concentration = $0
                                              mapping.setAutomaticHDRTarget()
                                          }), in: -1...1, label: { Text("Contrast") })
                        .controlReset { mapping.concentration = defaults.concentration; mapping.setAutomaticHDRTarget() }
                        .editorSliderTrack(EditorSliderTracks.contrast(tone: mapping.tonePosition, white: mapping.white))
                        .labelsHidden()
                }
                    .help("Zero is linear. Negative values reduce contrast around the tone position.")
            }
            .filmLock(.contrast)
            if showContrastDistribution {
                ToneDistributionEditor(mapping: $mapping)
                    .filmLock(.contrastDistribution)
            }
            Group {
                if mapping.hdrEnabled && !mapping.hdrHasContinuationRoom {
                    Label("No room for HDR continuation. Move Tone or the SDR white point below 1.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if mapping.hdrFallsBelowSDR {
                    Label("HDR cannot be darker than SDR. The curves cross.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .help("No HDR pixel can be darker than its SDR counterpart in a gain map based file. PQ and other direct HDR formats are not affected. You may add a small amount of HDR Gain to fix this issue.")
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("HDR Gain")
                    ControlInfo(.hdrGain)
                    AdjustmentField(title: "HDR Gain", value: Binding(get: { mapping.hdrGain }, set: {
                        mapping.hdrGain = $0 == 0 ? 0 : max(1,$0); onHDRGainAdjustment()
                    }), range: 0...Double.greatestFiniteMagnitude, unit: "×")
                    if !mapping.hdrEnabled { Text("Off").foregroundStyle(.secondary) }
                }
                HStack {
                    Image(systemName: "sun.max")
                        .frame(width: 22).accessibilityHidden(true)
                    EditorSlider(value: Binding(get: { mapping.hdrEnabled ? min(5, max(1, mapping.hdrGain)) : 0 }, set: { value in
                        mapping.hdrGain = value < 0.5 ? 0 : min(5, max(1, value))
                        onHDRGainAdjustment()
                    }), in: 0...5, onEditingChanged: { editing in
                        if editing, mapping.hdrGain > 5 {
                            mapping.hdrGain = 5
                            onHDRGainAdjustment()
                        }
                    }) { Text("HDR Gain") }
                        .editorSliderTicks([1, 2, 4])
                        .controlReset { mapping.hdrGain = defaults.hdrGain; onHDRGainAdjustment() }
                        .labelsHidden()
                }
            }
            .filmLock(.hdrGain)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("HDR Rolloff")
                    ControlInfo(.hdrRolloff)
                    AdjustmentField(title: "HDR Rolloff", value: Binding(get: { mapping.hdrRolloff }, set: {
                        mapping.hdrRolloff=$0; onHDRGainAdjustment()
                    }), range: -1...1, digits: 0, scale: 100, unit: "%")
                }
                HStack {
                    Image(systemName: "surfboard").frame(width: 22).accessibilityHidden(true)
                    EditorSlider(value: Binding(get: { mapping.hdrRolloff }, set: {
                        mapping.hdrRolloff = $0
                        onHDRGainAdjustment()
                    }), in: -1...1, label: { Text("HDR Rolloff") })
                        .controlReset { mapping.hdrRolloff = defaults.hdrRolloff; onHDRGainAdjustment() }
                        .labelsHidden()
                }
            }
            .disabled(!mapping.hdrEnabled).filmLock(.hdrRolloff)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Shadow Floor")
                    Spacer()
                    AdjustmentField(title: "Shadow Floor", value: $mapping.shadowFloor, range: 0...Double(Float.greatestFiniteMagnitude), digits: 3)
                }
                HStack {
                    Image(systemName: "film.circle.fill").frame(width: 22).accessibilityHidden(true)
                    EditorSlider(value: $mapping.shadowFloor, in: 0...0.05) { Text("Shadow Floor") }
                        .labelsHidden()
                        .controlReset { mapping.shadowFloor = defaults.shadowFloor }
                }
            }
            .filmLock(.shadowFloor)
            .help("Clips each linear RGB channel below this level to the same floor before tone mapping. Zero disables the floor.")

        }
        .font(.callout.monospacedDigit())
        .padding()
        .onChange(of: mapping.concentration) { _, contrast in
            if abs(contrast) > 0.1 { showLowContrastTip = false }
        }
        .onDisappear { showLowContrastTip = false }
    }
}

struct HistogramToneCurve: View {
    let mapping: ToneMapping
    let hdrPreview: Bool
    var inputMaximum = 1.0

    var body: some View {
        Canvas { context, size in
            let sdrCurve = mapping.curve(hdr: false)
            let hdrCurve = mapping.curve(hdr: true)
            let maximum = hdrPreview ? max(1.25, mapping.hdrMax * 1.08) : 1.25
            func point(_ input: Double, _ output: Double) -> CGPoint {
                CGPoint(x: input / inputMaximum * size.width,
                        y: size.height * (1 - max(0, output) / maximum))
            }
            let whiteY = point(mapping.white, 1).y
            context.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: whiteY)),
                         with: .color(.orange.opacity(0.035)))
            var reference = Path()
            reference.move(to: CGPoint(x: 0, y: whiteY))
            reference.addLine(to: CGPoint(x: size.width, y: whiteY))
            context.stroke(reference, with: .color(.white.opacity(0.5)),
                           style: StrokeStyle(lineWidth: 1, dash: [5, 4]))

            for (curve, color) in (mapping.hdrEnabled ? [(hdrCurve, Color.orange), (sdrCurve, Color.mint)] : [(sdrCurve, Color.mint)]) {
                var path = Path()
                for index in 0...2000 {
                    let input = Double(index) / 2000 * inputMaximum
                    let p = point(input, curve.value(at: max(input, mapping.shadowFloor)))
                    if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                context.stroke(path, with: .color(.black.opacity(0.8)), lineWidth: 4)
                context.stroke(path, with: .color(color), lineWidth: 2)
            }
            var peakLine = Path()
            peakLine.move(to: CGPoint(x: mapping.peakPosition / inputMaximum * size.width, y: 0))
            peakLine.addLine(to: CGPoint(x: mapping.peakPosition / inputMaximum * size.width, y: size.height))
            context.stroke(peakLine, with: .color(.yellow.opacity(0.6)),
                           style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
            let crossing = point(mapping.white, 1)
            if crossing.x <= size.width {
                context.fill(Path(ellipseIn: CGRect(x: crossing.x - 3, y: crossing.y - 3,
                                                   width: 6, height: 6)), with: .color(.white))
            }
            let hdrLabel = mapping.hdrEnabled
                ? Text("HDR Output +\(log2(mapping.hdrMax), specifier: "%.2f") stops")
                : Text("HDR Off")
            context.draw(hdrLabel
                .font(.caption2.monospacedDigit()).foregroundStyle(.orange),
                         at: CGPoint(x: size.width - 5, y: 3), anchor: .topTrailing)
            context.draw(Text("1.0 · SDR white").font(.caption2).foregroundStyle(.white),
                         at: CGPoint(x: size.width - 5, y: whiteY - 3), anchor: .bottomTrailing)
        }
        .clipped()
        .accessibilityLabel("Two tone curves. SDR reaches one at the white point; HDR reaches its maximum at input one.")
    }
}
