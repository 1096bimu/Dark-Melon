import SwiftUI

struct VectorscopeView: View {
    @Environment(\.resetMapping) private var defaults
    @Environment(\.lockedFilmItems) private var lockedItems
    let source: CGImage?
    let hoverSource: CGImage?
    let hoverRevision: UUID
    let revision: UUID
    let colorSpace: ProcessingColorSpace
    @Binding var mapping: ToneMapping
    @Binding var pickingWhiteBalance: Bool
    var resetRAWBalance: (() -> Void)? = nil
    var convertWhiteBalance: (() -> Void)? = nil
    var commitRAWBalance: () -> Void = {}
    private func setRAWBalance(temperature: Float) {
        guard var whiteBalance = mapping.rawWhiteBalance else { return }
        whiteBalance.temperature = temperature
        whiteBalance.tint = 0
        mapping.rawWhiteBalance = whiteBalance
        commitRAWBalance()
    }

    private var balance: WhiteBalance {
        get { mapping.whiteBalance }
        nonmutating set { mapping.whiteBalance = newValue }
    }
    @State private var zoom = 2.0
    @GestureState private var pinch = 1.0
    @AppStorage(ScopeGradient.preferenceKey) private var gradient = ScopeGradient.inferno
    private var magnification: Double { min(16, max(1, zoom * pinch)) }
    @State private var worker: GPUVectorscope?
    @State private var scope: ScopeTexture?
    @State private var errorMessage: String?
    @State private var lastTranslation = CGSize.zero

    private static let warmDirection: CGPoint = {
        let warm = ScopeProjection.lab(TemperatureLocus.referenceRGB(4500, space: .sRGB), space: .sRGB)
        let cool = ScopeProjection.lab(TemperatureLocus.referenceRGB(7500, space: .sRGB), space: .sRGB)
        let x = warm.y - cool.y, y = -(warm.z - cool.z)
        let length = hypot(x, y)
        return CGPoint(x: x / length, y: y / length)
    }()

    private var gainValues: some View {
        HStack(spacing: 6) {
            Text("R")
            AdjustmentField(title: "Red gain", value: $mapping.whiteBalance.red, range: 0.000001...10000, digits: 3, width: 60)
            Text("G")
            AdjustmentField(title: "Green gain", value: $mapping.whiteBalance.green, range: 0.000001...10000, digits: 3, width: 60)
            Text("B")
            AdjustmentField(title: "Blue gain", value: $mapping.whiteBalance.blue, range: 0.000001...10000, digits: 3, width: 60)
        }.filmLock(.rgbWhiteBalance)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !mapping.color.monochrome {
                HStack {
                    Text("Vectorscope").fontWeight(.medium)
                    Spacer()
                    Button("\(magnification, format: .number.precision(.fractionLength(1)))×") { zoom = 2 }
                        .help("Pinch to zoom the chroma radius. Click to reset to 2×.")
                    #if os(macOS)
                    if !mapping.color.monochrome {
                    Button(pickingWhiteBalance ? "Cancel White Balance Sample" : "Sample White Balance", systemImage: "eyedropper") {
                        pickingWhiteBalance.toggle()
                    }
                    .labelStyle(.iconOnly)
                    .disabled(mapping.blackAndWhite.isEnabled).filmLock(.rgbWhiteBalance)
                    .tint(pickingWhiteBalance ? .accentColor : .primary)
                    .help("Click a center in the preview, drag a circle, then click again to set white balance. Shortcut: W.")
                    }
                    #endif
                    if !mapping.color.monochrome || resetRAWBalance != nil {
                    Button("Reset WB") {
                        if let resetRAWBalance { resetRAWBalance() } else { balance = WhiteBalance() }
                    }
                        .disabled((resetRAWBalance == nil && balance == WhiteBalance()) || mapping.blackAndWhite.isEnabled)
                    }
                }
                if pickingWhiteBalance {
                    Text("Click center, drag radius, click again to apply. Click the eyedropper to cancel.")
                        .foregroundStyle(.secondary)
                }
                Text("SDR · \(colorSpace.rawValue) · Lab · D50")
                    .foregroundStyle(.secondary)
                GeometryReader { geometry in
                    let diameter = max(1, min(geometry.size.width, geometry.size.height) - 36)
                    ZStack {
                        Color.black
                        if let scope {
                            ScopeMetalView(frame: scope, gradient: gradient)
                                .frame(width: diameter, height: diameter)
                                .clipShape(Circle())
                        }
                        Canvas { context, size in
                            let center = CGPoint(x: size.width / 2, y: size.height / 2)
                            let radius = diameter / 2
                            for fraction in [0.25, 0.5, 0.75, 1.0] {
                                let r = radius * fraction
                                context.stroke(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r,
                                    width: r * 2, height: r * 2)),
                                    with: .color(.white.opacity(0.2)), lineWidth: 0.5)
                            }
                            context.draw(Text("\(128.0 / magnification, format: .number.precision(.fractionLength(0)))")
                                .font(.caption2).foregroundStyle(.secondary),
                                at: CGPoint(x: center.x, y: center.y + radius - 8))
                            let names = EditorGraphStyle.colorNames
                            let colors = EditorGraphStyle.colorLabels
                            let primaries: [(Double, Double, Double)] = [(1,0,0), (1,1,0), (0,1,0), (0,1,1), (0,0,1), (1,0,1)]
                            for index in 0..<6 {
                                let rgb = primaries[index]
                                let p = ScopeProjection.point(r: rgb.0, g: rgb.1, b: rgb.2, space: colorSpace)
                                let length = hypot(p.x, p.y)
                                let dx = p.x / length, dy = p.y / length
                                var line = Path()
                                line.move(to: center)
                                line.addLine(to: CGPoint(x: center.x + dx * radius, y: center.y + dy * radius))
                                context.stroke(line, with: .color(.white.opacity(0.15)), lineWidth: 0.5)
                                context.draw(Text(names[index]).font(.caption2.bold()).foregroundStyle(colors[index]),
                                    at: CGPoint(x: center.x + dx * (radius + 12), y: center.y + dy * (radius + 12)))
                            }
                            // General warmth direction in Lab, independent of scene exposure and WB.
                            let direction = Self.warmDirection
                            for (sign, label, color) in [(1.0, "Warmer", Color.orange), (-1.0, "Colder", Color.cyan)] {
                                let dx = direction.x * sign, dy = direction.y * sign
                                let start = CGPoint(x: center.x + dx * radius * 0.18, y: center.y + dy * radius * 0.18)
                                let tip = CGPoint(x: center.x + dx * radius * 0.48, y: center.y + dy * radius * 0.48)
                                var arrow = Path()
                                arrow.move(to: start); arrow.addLine(to: tip)
                                arrow.move(to: CGPoint(x: tip.x - dx * 7 - dy * 4, y: tip.y - dy * 7 + dx * 4))
                                arrow.addLine(to: tip)
                                arrow.addLine(to: CGPoint(x: tip.x - dx * 7 + dy * 4, y: tip.y - dy * 7 - dx * 4))
                                context.stroke(arrow, with: .color(.black.opacity(0.8)), lineWidth: 4)
                                context.stroke(arrow, with: .color(color), lineWidth: 1.5)
                                context.draw(Text(LocalizedStringKey(label)).font(.caption2).foregroundStyle(color),
                                             at: CGPoint(x: center.x + dx * radius * 0.65, y: center.y + dy * radius * 0.65))
                            }

                        }
                        HoverPixelOverlay(source: hoverSource, revision: hoverRevision, space: colorSpace) { context, size, rgb in
                            let bounded = SIMD3(min(1,max(0,rgb.x)), min(1,max(0,rgb.y)), min(1,max(0,rgb.z)))
                            let lab = ScopeProjection.lab(bounded, space: colorSpace)
                            let marker = CGPoint(x: lab.y / ScopeProjection.radius, y: -lab.z / ScopeProjection.radius)
                            let center = CGPoint(x: size.width / 2, y: size.height / 2)
                            let radius = diameter / 2
                            let x = marker.x * magnification, y = marker.y * magnification
                            let distance = hypot(x, y)
                            let scale = distance > 1 ? 0.97 / distance : 1
                            let point = CGPoint(x: center.x + x * scale * radius,
                                                y: center.y + y * scale * radius)
                            let color: Color = distance > 1 ? .orange : .white
                            ScopePixelMarker.draw(in: &context, at: point, color: color)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        guard !mapping.blackAndWhite.isEnabled, !mapping.color.monochrome else { return }
                        guard pinch == 1 else { lastTranslation = value.translation; return }
                        guard !lockedItems.contains(.rgbWhiteBalance) else { return }
                        balance.nudge(dx: (value.translation.width - lastTranslation.width) / diameter,
                                      dy: (value.translation.height - lastTranslation.height) / diameter,
                                      colorSpace: colorSpace)
                        lastTranslation = value.translation
                    }.onEnded { _ in lastTranslation = .zero })
                    .simultaneousGesture(MagnifyGesture().updating($pinch) { value, state, _ in
                        state = value.magnification
                    }.onEnded { value in
                        zoom = min(16, max(1, zoom * value.magnification))
                    })
                    .accessibilityLabel("White balance vectorscope")
                    .accessibilityHint("Drag toward a hue to increase that color in the image.")
                }
                .aspectRatio(1, contentMode: .fit)
                if let errorMessage { Text(errorMessage).foregroundStyle(.secondary) }
            }
            if mapping.rawWhiteBalance != nil {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("White Balance").fontWeight(.medium)
                        Spacer()
                        if mapping.color.monochrome, let resetRAWBalance {
                            Button("Reset WB", action: resetRAWBalance)
                        }
                    }
                    if !mapping.color.monochrome {
                        gainValues
                        if let convertWhiteBalance {
                            HStack {
                                Spacer()
                                Button("D") { setRAWBalance(temperature: 5500) }
                                    .help("5500 K · Tint 0")
                                    .filmLock(.rawWhiteBalance)
                                Button("T") { setRAWBalance(temperature: 3200) }
                                    .help("3200 K · Tint 0")
                                    .filmLock(.rawWhiteBalance)
                                Button("Convert to WB", action: convertWhiteBalance)
                                    .disabled(balance == WhiteBalance() || lockedItems.contains(.rgbWhiteBalance) || lockedItems.contains(.rawWhiteBalance))
                            }
                        }
                    }
                    HStack {
                        Text("Temperature"); Spacer()
                        AdjustmentField(title: "Temperature", value: Binding(
                            get: { Double(mapping.rawWhiteBalance?.temperature ?? 6500) },
                            set: { mapping.rawWhiteBalance?.temperature = Float($0) }),
                            range: 2000...50000, digits: 0, unit: "K", commit: commitRAWBalance).filmLock(.rawWhiteBalance)
                    }
                    EditorSlider(value: Binding(get: { Double(mapping.rawWhiteBalance?.temperature ?? 6500) }, set: {
                        mapping.rawWhiteBalance?.temperature = Float($0)
                    }), in: 2000...10000, onEditingChanged: { editing in
                        if !editing { commitRAWBalance() }
                    }).filmLock(.rawWhiteBalance)
                    .controlReset { if let wb = defaults.rawWhiteBalance { mapping.rawWhiteBalance?.temperature = wb.temperature } }
                    .editorSliderTrack(EditorSliderTracks.temperature)
                    HStack {
                        Text("Tint"); Spacer()
                        AdjustmentField(title: "Tint", value: Binding(
                            get: { Double(mapping.rawWhiteBalance?.tint ?? 0) },
                            set: { mapping.rawWhiteBalance?.tint = Float($0) }),
                            range: -150...150, digits: 2, commit: commitRAWBalance).filmLock(.rawWhiteBalance)
                    }
                    EditorSlider(value: Binding(get: { Double(mapping.rawWhiteBalance?.tint ?? 0) }, set: {
                        mapping.rawWhiteBalance?.tint = Float($0)
                    }), in: -50...50, onEditingChanged: { editing in
                        if !editing { commitRAWBalance() }
                    }).filmLock(.rawWhiteBalance)
                    .controlReset { if let wb = defaults.rawWhiteBalance { mapping.rawWhiteBalance?.tint = wb.tint } }
                    .editorSliderTrack(EditorSliderTracks.tint)
                }
                .disabled(mapping.blackAndWhite.isEnabled)
            } else if !mapping.color.monochrome {
                gainValues
            }
        }
        .font(.caption)
        .padding(12)
        .task(id: ScopeRequest(revision: source == nil ? nil : revision, mapping: mapping, zoom: magnification, space: colorSpace)) {
            guard !mapping.color.monochrome, let source else { scope = nil; return }
            do {
                if worker == nil { worker = try GPUVectorscope() }
                let result = try await worker!.render(source: source, mapping: mapping, space: colorSpace, zoom: magnification)
                try Task.checkCancellation()
                scope = result
                errorMessage = nil
            } catch is CancellationError {
            } catch { errorMessage = error.localizedDescription }
        }
    }
}

private struct ScopeRequest: Equatable {
    let revision: UUID?
    let mapping: ToneMapping
    let zoom: Double
    let space: ProcessingColorSpace
}
