import SwiftUI

struct HistogramPoints: View {
    @Binding var mapping: ToneMapping
    @State private var draggingBlack: Bool?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach([true, false], id: \.self) { isBlack in
                    let point = isBlack ? mapping.black : mapping.white
                    let x = min(geometry.size.width - 1, max(1, geometry.size.width * point))
                    Path { path in
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                    }
                    .stroke(isBlack ? .white : .black, lineWidth: 4)
                    Path { path in
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                    }
                    .stroke(isBlack ? .black : .white, lineWidth: 2)
                    Text(isBlack ? "B" : "W")
                        .font(.caption2.bold())
                        .foregroundStyle(isBlack ? .white : .black)
                        .padding(4)
                        .background(isBlack ? Color.black : Color.white, in: RoundedRectangle(cornerRadius: 3))
                        .position(x: min(geometry.size.width - 10, max(10, x)), y: isBlack ? 12 : 32)
                        .accessibilityLabel(isBlack ? "Black point" : "White point")
                        .accessibilityValue(point.formatted(.number.precision(.fractionLength(4))))
                        .accessibilityAdjustableAction { direction in
                            update(point + (direction == .increment ? 0.005 : -0.005), black: isBlack)
                        }
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let width = max(1, geometry.size.width)
                if draggingBlack == nil {
                    let start = value.startLocation.x / width
                    draggingBlack = abs(start - mapping.black) < abs(start - mapping.white)
                }
                update(value.location.x / width, black: draggingBlack == true)
            }.onEnded { _ in draggingBlack = nil })
        }
    }

    private func update(_ value: Double, black: Bool) {
        if black {
            mapping.black = max(0, min(mapping.white - ToneMapping.minimumRange, value))
        } else {
            mapping.white = min(1, max(mapping.black + ToneMapping.minimumRange, value))
        }
    }
}

struct SlopeEditor: View {
    @Binding var mapping: ToneMapping
    @Binding var autoTones: Bool
    var onToneChanged: () -> Void = {}
    var onContrastChanged: () -> Void = {}
    var onContrastAdjustment: () -> Void = {}
    var onHDRContrastAdjustment: () -> Void = {}
    var onToneEditingChanged: (Bool) -> Void = { _ in }
    @State private var showLowContrastTip = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Tone")
                    ControlInfo(.tone)
                    Text(mapping.tonePosition, format: .number.precision(.fractionLength(3)))
                    Spacer()
                    Toggle("Auto Tones", isOn: $autoTones)
                        #if os(macOS)
                        .toggleStyle(.checkbox)
                        #endif
                        .help("Adjust white point and HDR when you release the Tone slider.")
                    ControlInfo(.autoTones)
                }
                HStack {
                    Image(systemName: "swirl.circle.righthalf.filled")
                        .frame(width: 22).accessibilityHidden(true)
                Slider(value: Binding(get: { 1 - mapping.tonePosition },
                                      set: {
                                          if mapping.tonePosition != 1 - $0 { onToneChanged() }
                                          mapping.tonePosition = 1 - $0
                                          showLowContrastTip = abs(mapping.concentration) <= 0.1
                                      }),
                       in: 0...1) {
                    Text("Tone")
                } onEditingChanged: { editing in
                    onToneEditingChanged(editing)
                }
                        .labelsHidden()
                }
                if showLowContrastTip {
                    Label("Tone adjustment is ineffective at low contrast.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Contrast")
                    ControlInfo(.contrast)
                    Text(mapping.concentration, format: .percent.precision(.fractionLength(0)))
                }
                HStack {
                    Image(systemName: "circle.lefthalf.striped.horizontal")
                        .frame(width: 22).accessibilityHidden(true)
                    Slider(value: Binding(get: { mapping.concentration },
                                          set: {
                                              if mapping.concentration != $0 { onContrastChanged() }
                                              mapping.setContrastPreservingHDR($0)
                                              onContrastAdjustment()
                                          }), in: -1...1) { Text("Contrast") }
                        onEditingChanged: { editing in
                            if editing { onContrastAdjustment() }
                        }
                        .labelsHidden()
                }
                    .help("Zero is linear. Negative values reduce contrast around the tone position.")
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("HDR Contrast")
                    ControlInfo(.hdrContrast)
                    Text(mapping.hdrConcentrationOffset,
                         format: .percent.precision(.fractionLength(0)).sign(strategy: .always()))
                }
                HStack {
                    Image(systemName: "circle.lefthalf.filled.righthalf.striped.horizontal")
                        .frame(width: 22).accessibilityHidden(true)
                    Slider(value: Binding(get: { mapping.hdrConcentrationOffset }, set: {
                        mapping.hdrConcentrationOffset = $0
                        onHDRContrastAdjustment()
                    }), in: -2...2) { Text("HDR Contrast") }
                        onEditingChanged: { editing in
                            if editing { onHDRContrastAdjustment() }
                        }
                        .labelsHidden()
                        .disabled(!mapping.hdrEnabled)
                }
                    .help("Offset from Contrast for the HDR curve. Adjusts automatically when Contrast changes to preserve the HDR curve.")
                if mapping.hdrFallsBelowSDR {
                    Label("HDR cannot be darker than SDR. The curves cross.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("HDR Gain")
                    ControlInfo(.hdrGain)
                    if !mapping.hdrEnabled { Text("Off").foregroundStyle(.secondary) }
                    else { TextField("HDR Gain", value: $mapping.hdrMax,
                              format: .number.precision(.fractionLength(2)))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .onChange(of: mapping.hdrMax) { _, value in
                            mapping.hdrMax = value.isFinite ? (value < 1.5 ? 1 : min(20, max(2, value))) : 4
                        }
                    }
                }
                HStack {
                    Image(systemName: "sun.max")
                        .frame(width: 22).accessibilityHidden(true)
                    Slider(value: Binding(get: { mapping.hdrMax }, set: { value in
                        mapping.hdrMax = value < 1.5 ? 1 : max(2, value)
                    }), in: 1...20) { Text("HDR Gain") }
                        .labelsHidden()
                }
            }
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

    var body: some View {
        Canvas { context, size in
            let sdrCurve = mapping.curve(hdr: false)
            let hdrCurve = mapping.curve(hdr: true)
            let maximum = max(1.25, mapping.hdrMax * 1.08)
            func point(_ input: Double, _ output: Double) -> CGPoint {
                CGPoint(x: input * size.width,
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

            for (curve, color) in (mapping.hdrEnabled ? [(sdrCurve, Color.mint), (hdrCurve, Color.orange)] : [(sdrCurve, Color.mint)]) {
                var path = Path()
                for index in 0...2000 {
                    let input = Double(index) / 2000
                    let p = point(input, curve.value(at: input))
                    if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                context.stroke(path, with: .color(.black.opacity(0.8)), lineWidth: 4)
                context.stroke(path, with: .color(color), lineWidth: 2)
            }
            var peakLine = Path()
            peakLine.move(to: CGPoint(x: mapping.peakPosition * size.width, y: 0))
            peakLine.addLine(to: CGPoint(x: mapping.peakPosition * size.width, y: size.height))
            context.stroke(peakLine, with: .color(.yellow.opacity(0.6)),
                           style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
            let crossing = point(mapping.white, 1)
            if crossing.x <= size.width {
                context.fill(Path(ellipseIn: CGRect(x: crossing.x - 3, y: crossing.y - 3,
                                                   width: 6, height: 6)), with: .color(.white))
            }
            context.draw(Text(mapping.hdrEnabled ? "HDR Gain \(mapping.hdrMax.formatted(.number.precision(.fractionLength(2))))" : "HDR Off")
                .font(.caption2.monospacedDigit()).foregroundStyle(.orange),
                         at: CGPoint(x: size.width - 5, y: 3), anchor: .topTrailing)
            context.draw(Text("1.0 · SDR white").font(.caption2).foregroundStyle(.white),
                         at: CGPoint(x: size.width - 5, y: whiteY - 3), anchor: .bottomTrailing)
        }
        .accessibilityLabel("Two tone curves. SDR reaches one at the white point; HDR reaches its maximum at input one.")
    }
}
