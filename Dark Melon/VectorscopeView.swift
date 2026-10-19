import SwiftUI

struct VectorscopeView: View {
    let source: CGImage?
    let temperatureSamples: [TemperatureLocus.Sample]
    let revision: UUID
    let colorSpace: ProcessingColorSpace
    let whitePoint: RAWWhitePoint?
    @Binding var mapping: ToneMapping
    @Binding var pickingWhiteBalance: Bool
    private var balance: WhiteBalance {
        get { mapping.whiteBalance }
        nonmutating set { mapping.whiteBalance = newValue }
    }
    @State private var zoom = 2.0
    @GestureState private var pinch = 1.0
    @State private var boundaries: [ScopeGamutBoundary.Boundary] = []
    private var magnification: Double { min(16, max(1, zoom * pinch)) }
    @State private var worker: GPUVectorscope?
    @State private var scope: ScopeTexture?
    @State private var errorMessage: String?
    @State private var lastTranslation = CGSize.zero

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
                .help("Click a center in the preview, drag a circle, then click again to set white balance.")
                #endif
                Button("Reset WB") { balance = WhiteBalance() }
                    .disabled(balance == WhiteBalance() || mapping.blackAndWhite.isEnabled)
            }
            if pickingWhiteBalance {
                Text("Click center, drag radius, click again to apply. Click the eyedropper to cancel.")
                    .foregroundStyle(.secondary)
            }
            Text("SDR · \(colorSpace.rawValue) · Y′UV · BT.601")
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
                        context.draw(Text("\(0.75 / magnification, format: .number.precision(.fractionLength(3)))")
                            .font(.caption2).foregroundStyle(.secondary),
                            at: CGPoint(x: center.x, y: center.y + radius - 8))
                        var axes = Path()
                        axes.move(to: CGPoint(x: center.x - radius, y: center.y))
                        axes.addLine(to: CGPoint(x: center.x + radius, y: center.y))
                        axes.move(to: CGPoint(x: center.x, y: center.y - radius))
                        axes.addLine(to: CGPoint(x: center.x, y: center.y + radius))
                        context.stroke(axes, with: .color(.white.opacity(0.25)), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                        context.draw(Text("+U").font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: center.x + radius - 14, y: center.y - 10))
                        context.draw(Text("+V").font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: center.x + 14, y: center.y - radius + 10))
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
                            clipped.stroke(path, with: .color(index == 0 ? .cyan : .pink), lineWidth: 1)
                        }
                        let names = ["R", "Y", "G", "C", "B", "M"]
                        let colors: [Color] = [.red, .yellow, .green, .cyan, .blue, .pink]
                        let primaries: [(Double, Double, Double)] = [(1,0,0), (1,1,0), (0,1,0), (0,1,1), (0,0,1), (1,0,1)]
                        for index in 0..<6 {
                            let rgb = primaries[index]
                            let p = ScopeProjection.point(r: rgb.0, g: rgb.1, b: rgb.2)
                            let length = hypot(p.x, p.y)
                            let dx = p.x / length, dy = p.y / length
                            var line = Path()
                            line.move(to: center)
                            line.addLine(to: CGPoint(x: center.x + dx * radius, y: center.y + dy * radius))
                            context.stroke(line, with: .color(.white.opacity(0.15)), lineWidth: 0.5)
                            context.draw(Text(names[index]).font(.caption2.bold()).foregroundStyle(colors[index]),
                                at: CGPoint(x: center.x + dx * (radius + 12), y: center.y + dy * (radius + 12)))
                        }
                        let samples = temperatureSamples
                        func position(_ sample: TemperatureLocus.Sample) -> CGPoint {
                            CGPoint(x: center.x + sample.point.x * radius * magnification,
                                    y: center.y + sample.point.y * radius * magnification)
                        }
                        var locus = Path()
                        for (index, sample) in samples.enumerated() {
                            if index == 0 { locus.move(to: position(sample)) }
                            else { locus.addLine(to: position(sample)) }
                        }
                        clipped.stroke(locus, with: .color(.black.opacity(0.8)), lineWidth: 3)
                        clipped.stroke(locus, with: .color(.yellow.opacity(0.85)),
                                       style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                        let markers: [(sample: TemperatureLocus.Sample, label: String)] = whitePoint != nil
                            ? samples.filter { TemperatureLocus.marks.contains($0.kelvin) }.map { ($0, "\($0.kelvin)K") }
                            : [samples.first.map { ($0, "Warm") }, samples.last.map { ($0, "Cool") }].compactMap { $0 }
                        for (index, marker) in markers.enumerated() {
                            let point = position(marker.sample)
                            guard hypot(point.x - center.x, point.y - center.y) <= radius else { continue }
                            let left = whitePoint != nil ? index < 3 : index == 0
                            let row = whitePoint != nil ? index % 3 - 1 : (left ? -1 : 1)
                            let label = CGPoint(x: center.x + (left ? -0.68 : 0.68) * radius,
                                                y: center.y + CGFloat(row) * 27)
                            var leader = Path()
                            leader.move(to: point)
                            leader.addLine(to: CGPoint(x: label.x + (left ? 21 : -21), y: label.y))
                            context.stroke(leader, with: .color(.yellow.opacity(0.4)), lineWidth: 0.5)
                            context.fill(Path(ellipseIn: CGRect(x: point.x - 2, y: point.y - 2,
                                                                width: 4, height: 4)), with: .color(.yellow))
                            let text = Text(marker.label).font(.caption2)
                            context.draw(text.foregroundStyle(.black), at: CGPoint(x: label.x + 1, y: label.y + 1))
                            context.draw(text.foregroundStyle(.yellow), at: label)
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
                        Text(boundary.name).foregroundStyle(index == 0 ? .cyan : .pink)
                    }
                    Text("projected limits ≈").foregroundStyle(.secondary)
                }
                .help("Approximate outer gamut projections across all lightness levels. Outside indicates out of gamut; inside does not guarantee membership because this scope omits lightness.")
            }
            Text(whitePoint != nil ? "Kelvin guide · RAW white-balance reference" : "Warm–cool guide · midpoint of black–white range")
                .foregroundStyle(.yellow.opacity(0.85))
                .help("Reference pixels start at linear luminance halfway between the black and white points and follow the image’s white balance and SDR tone curve. Warm and Cool indicate relative reference directions. For RAW, Kelvin labels use a chromatic-adaptation approximation based on the decoder’s recorded white point, including tint. Other images show relative directions only.")
            Text(errorMessage ?? "Drag to adjust white balance · Brighter dots = more pixels")
                .foregroundStyle(.secondary)
            Text("R \(balance.red, format: .number.precision(.fractionLength(3)))  G \(balance.green, format: .number.precision(.fractionLength(3)))  B \(balance.blue, format: .number.precision(.fractionLength(3)))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(12)
        .task(id: colorSpace) {
            let space = colorSpace
            let result = await Task.detached(priority: .userInitiated) { ScopeGamutBoundary.boundaries(in: space) }.value
            guard !Task.isCancelled else { return }
            boundaries = result
        }
        .task(id: ScopeRequest(revision: revision, mapping: mapping, zoom: magnification)) {
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
    let revision: UUID
    let mapping: ToneMapping
    let zoom: Double
}
