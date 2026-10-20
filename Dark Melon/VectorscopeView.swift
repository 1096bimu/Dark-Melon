import SwiftUI

struct VectorscopeView: View {
    let source: CGImage?
    let hoverSource: CGImage?
    let hoverPosition: CGPoint?
    let hoverRevision: UUID
    let revision: UUID
    let colorSpace: ProcessingColorSpace
    @Binding var mapping: ToneMapping
    @Binding var pickingWhiteBalance: Bool
    var resetRAWBalance: (() -> Void)? = nil
    var convertWhiteBalance: (() -> Void)? = nil
    @FocusState private var focusedWBField: Int?
    @State private var editedWBField = false
    var commitRAWBalance: () -> Void = {}
    private var balance: WhiteBalance {
        get { mapping.whiteBalance }
        nonmutating set { mapping.whiteBalance = newValue }
    }
    @State private var hoverSampler = ScopeHoverSampler()
    @State private var hoveredPoint: CGPoint?
    @State private var sampledRevision: UUID?
    private var hoverMarker: CGPoint? {
        hoverPosition != nil && sampledRevision == hoverRevision ? hoveredPoint : nil
    }
    @State private var zoom = 2.0
    @GestureState private var pinch = 1.0
    @State private var boundaries: [ScopeGamutBoundary.Boundary] = []
    private var magnification: Double { min(16, max(1, zoom * pinch)) }
    @State private var worker: GPUVectorscope?
    @State private var scope: ScopeTexture?
    @State private var errorMessage: String?
    @State private var lastTranslation = CGSize.zero

    private static let gamutColors: [Color] = [.cyan, .pink, .orange]
    private static let warmDirection: CGPoint = {
        let warm = ScopeProjection.lab(TemperatureLocus.referenceRGB(4500, space: .sRGB), space: .sRGB)
        let cool = ScopeProjection.lab(TemperatureLocus.referenceRGB(7500, space: .sRGB), space: .sRGB)
        let x = warm.y - cool.y, y = -(warm.z - cool.z)
        let length = hypot(x, y)
        return CGPoint(x: x / length, y: y / length)
    }()

    private var gainValues: some View {
        Text("R \(balance.red, format: .number.precision(.fractionLength(3)))  G \(balance.green, format: .number.precision(.fractionLength(3)))  B \(balance.blue, format: .number.precision(.fractionLength(3)))")
            .monospacedDigit()
    }

    private func commitWBField() {
        guard editedWBField else { return }
        editedWBField = false
        commitRAWBalance()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Vectorscope").fontWeight(.medium)
                Spacer()
                Button("\(magnification, format: .number.precision(.fractionLength(1)))×") { zoom = 2 }
                    .help("Pinch to zoom the chroma radius. Click to reset to 2×.")
                #if os(macOS)
                Button(pickingWhiteBalance ? "Cancel White Balance Sample" : "Sample White Balance", systemImage: "eyedropper") {
                    pickingWhiteBalance.toggle()
                }
                .labelStyle(.iconOnly)
                .disabled(mapping.blackAndWhite.isEnabled)
                .tint(pickingWhiteBalance ? .accentColor : .primary)
                .help("Click a center in the preview, drag a circle, then click again to set white balance. Shortcut: W.")
                #endif
                Button("Reset WB") {
                    if let resetRAWBalance { resetRAWBalance() } else { balance = WhiteBalance() }
                }
                    .disabled((resetRAWBalance == nil && balance == WhiteBalance()) || mapping.blackAndWhite.isEnabled)
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
                        ScopeMetalView(frame: scope)
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
                        var clipped = context
                        clipped.clip(to: Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                               width: diameter, height: diameter)))
                        for (index, boundary) in boundaries.enumerated() {
                            var path = Path()
                            for (i, p) in boundary.points.enumerated() {
                                let point = CGPoint(x: center.x + p.x * radius * magnification,
                                                    y: center.y + p.y * radius * magnification)
                                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                            }
                            path.closeSubpath()
                            clipped.stroke(path, with: .color(Self.gamutColors[index]), lineWidth: 1)
                        }
                        let names = ["R", "Y", "G", "C", "B", "M"]
                        let colors: [Color] = [.red, .yellow, .green, .cyan, .blue, .pink]
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
                        if let marker = hoverMarker {
                            let x = marker.x * magnification, y = marker.y * magnification
                            let distance = hypot(x, y)
                            let scale = distance > 1 ? 0.97 / distance : 1
                            let point = CGPoint(x: center.x + x * scale * radius,
                                                y: center.y + y * scale * radius)
                            let color: Color = distance > 1 ? .orange : .white
                            let ring = Path(ellipseIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10))
                            context.stroke(ring, with: .color(.black), lineWidth: 4)
                            context.stroke(ring, with: .color(color), lineWidth: 2)
                            var cross = Path()
                            cross.move(to: CGPoint(x: point.x - 9, y: point.y))
                            cross.addLine(to: CGPoint(x: point.x + 9, y: point.y))
                            cross.move(to: CGPoint(x: point.x, y: point.y - 9))
                            cross.addLine(to: CGPoint(x: point.x, y: point.y + 9))
                            context.stroke(cross, with: .color(.black), lineWidth: 3)
                            context.stroke(cross, with: .color(color), lineWidth: 1)
                        }
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    guard !mapping.blackAndWhite.isEnabled else { return }
                    guard pinch == 1 else { lastTranslation = value.translation; return }
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
            if !boundaries.isEmpty {
                HStack {
                    ForEach(Array(boundaries.enumerated()), id: \.offset) { index, boundary in
                        Text(boundary.name).foregroundStyle(Self.gamutColors[index])
                    }
                }
                .help("Approximate outer gamut projections across all lightness levels. Outside indicates out of gamut; inside does not guarantee membership because this scope omits lightness.")
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.secondary) }
            if mapping.rawWhiteBalance != nil {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("White Balance").fontWeight(.medium)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 6) {
                            gainValues
                            if let convertWhiteBalance {
                                Button("Convert to WB", action: convertWhiteBalance)
                                    .disabled(balance == WhiteBalance())
                            }
                        }
                    }
                    HStack {
                        Text("Temperature"); Spacer()
                        TextField("Temperature", value: Binding(get: { Double(mapping.rawWhiteBalance?.temperature ?? 6500) }, set: {
                            guard $0.isFinite else { return }
                            mapping.rawWhiteBalance?.temperature = Float(min(10000, max(2000, $0)))
                            editedWBField = true
                        }), format: .number.precision(.fractionLength(0)))
                            .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 80)
                            .focused($focusedWBField, equals: 0)
                            .onSubmit { commitWBField() }
                        Text("K")
                    }
                    Slider(value: Binding(get: { Double(mapping.rawWhiteBalance?.temperature ?? 6500) }, set: {
                        mapping.rawWhiteBalance?.temperature = Float($0)
                    }), in: 2000...10000, onEditingChanged: { editing in
                        if !editing { commitRAWBalance() }
                    })
                    HStack {
                        Text("Tint"); Spacer()
                        TextField("Tint", value: Binding(get: { Double(mapping.rawWhiteBalance?.tint ?? 0) }, set: {
                            guard $0.isFinite else { return }
                            mapping.rawWhiteBalance?.tint = Float(min(50, max(-50, $0)))
                            editedWBField = true
                        }), format: .number.precision(.fractionLength(2)))
                            .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 80)
                            .focused($focusedWBField, equals: 1)
                            .onSubmit { commitWBField() }
                    }
                    Slider(value: Binding(get: { Double(mapping.rawWhiteBalance?.tint ?? 0) }, set: {
                        mapping.rawWhiteBalance?.tint = Float($0)
                    }), in: -50...50, onEditingChanged: { editing in
                        if !editing { commitRAWBalance() }
                    })
                }
                .disabled(mapping.blackAndWhite.isEnabled)
            } else {
                gainValues
            }
        }
        .font(.caption)
        .padding(12)
        .onChange(of: focusedWBField) { old, _ in
            if old != nil { commitWBField() }
        }
        .task(id: ScopeHoverRequest(position: hoverPosition, revision: hoverRevision, space: colorSpace)) {
            guard let hoverPosition, let hoverSource else {
                hoveredPoint = nil
                return
            }
            do {
                let point = try await hoverSampler.sample(hoverSource, revision: hoverRevision,
                                                          position: hoverPosition, space: colorSpace)
                try Task.checkCancellation()
                hoveredPoint = point
                sampledRevision = hoverRevision
            } catch is CancellationError {
            } catch { hoveredPoint = nil }
        }
        .task(id: colorSpace) {
            let space = colorSpace
            let result = await Task.detached(priority: .userInitiated) { ScopeGamutBoundary.boundaries(in: space) }.value
            guard !Task.isCancelled else { return }
            boundaries = result
        }
        .task(id: ScopeRequest(revision: source == nil ? nil : revision, mapping: mapping, zoom: magnification, space: colorSpace)) {
            guard let source else { scope = nil; return }
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


private struct ScopeHoverRequest: Equatable {
    let position: CGPoint?
    let revision: UUID
    let space: ProcessingColorSpace
}
