import SwiftUI

/// Aspect-ratio geometry shared by the transform editor and saved recipes.
nonisolated enum CropGeometry {
    static let ratios: [(label: String, value: Double)] = [
        ("9:21", 9.0 / 21), ("9:16", 9.0 / 16), ("2:3", 2.0 / 3),
        ("3:4", 3.0 / 4), ("4:5", 4.0 / 5), ("1:1", 1),
        ("5:4", 5.0 / 4), ("4:3", 4.0 / 3), ("3:2", 3.0 / 2),
        ("16:9", 16.0 / 9), ("21:9", 21.0 / 9), ("65:24", 65.0 / 24)
    ]

    // Equal spacing for named ratios, with continuous logarithmic interpolation between them.
    static func ratio(at position: Double) -> Double {
        let p = min(Double(ratios.count - 1), max(0, position))
        let i = min(ratios.count - 2, Int(p))
        return exp(log(ratios[i].value) * (1 - (p - Double(i)))
                   + log(ratios[i + 1].value) * (p - Double(i)))
    }

    static func frame(in bounds: CGRect, ratio: Double) -> CGRect {
        let width = min(bounds.width, bounds.height * ratio)
        let height = width / ratio
        return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2,
                      width: width, height: height)
    }
}

struct TransformControls: View {
    let cropping: Bool
    let image: CGImage?
    let polygon: [CGPoint]
    let resolution: CGSize
    let toggle: () -> Void
    let resetPerspective: () -> Void
    let resetRotation: () -> Void
    let resetAll: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Transform").font(.headline)
            if let image { CropOverview(image: image, polygon: polygon) }
            ViewThatFits(in: .horizontal) {
                HStack { transformButton; resetButtons }
                VStack(alignment: .leading) { transformButton; resetButtons }
            }
            Text("Approx. \(Int(resolution.width)) × \(Int(resolution.height)) pixels")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }
    private var transformButton: some View {
        Button("Transform", systemImage: "crop", action: toggle)
            .buttonStyle(.bordered).tint(cropping ? .accentColor : nil)
            .help("Enter transform mode; click again to apply.")
    }
    private var resetButtons: some View {
        HStack {
            Button("Reset Perspective", action: resetPerspective)
            Button("Reset Rotation", action: resetRotation)
            Button("Reset Transform", action: resetAll)
        }.buttonStyle(.bordered).controlSize(.small)
    }
}

/// Full-photo reference; only four points change while the main preview is manipulated.
private struct CropOverview: View {
    let image: CGImage
    let polygon: [CGPoint]

    var body: some View {
        Image(decorative: image, scale: 1)
            .resizable().scaledToFit()
            .overlay {
                Canvas { context, size in
                    guard polygon.count == 4 else { return }
                    let points = polygon.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
                    var path = Path()
                    path.addLines(points)
                    path.closeSubpath()
                    context.fill(path, with: .color(.cyan.opacity(0.12)))
                    context.stroke(path, with: .color(.black.opacity(0.8)), lineWidth: 4)
                    context.stroke(path, with: .color(.cyan), lineWidth: 2)
                    for point in points {
                        context.fill(Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)),
                                     with: .color(.white))
                    }
                }
            }
            .clipped()
            .accessibilityLabel("Full photo with transformed crop area")
    }
}

struct CropRatioControls: View {
    @Binding var position: Double
    private var ratio: Double { CropGeometry.ratio(at: position) }
    private var label: String {
        let nearest = position.rounded()
        if abs(position - nearest) < 0.001 { return CropGeometry.ratios[Int(nearest)].label }
        return ratio.formatted(.number.precision(.fractionLength(3))) + ":1"
    }
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Aspect Ratio")
                Spacer()
                Text(label).monospacedDigit()
            }
            Slider(value: $position, in: 0...Double(CropGeometry.ratios.count - 1), onEditingChanged: { editing in
                // Small magnetic stops retain arbitrary ratios everywhere else.
                if !editing, abs(position - position.rounded()) < 0.12 { position = position.rounded() }
            }) { Text("Aspect Ratio") }
            HStack(spacing: 0) {
                ForEach(CropGeometry.ratios.indices, id: \.self) { i in
                    Button(CropGeometry.ratios[i].label) { position = Double(i) }
                        .buttonStyle(.plain)
                        .font(.caption2)
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(abs(position - Double(i)) < 0.001 ? Color.accentColor : .secondary)
                }
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .background(.black)
    }
}

#if !os(macOS)
/// The mobile preview has no AppKit viewport; use native SwiftUI touch gestures.
struct MobileCropPreview: View {
    let image: CGImage
    let hdr: Bool
    let ratio: Double
    @Binding var transform: CropTransform
    let savedTransform: TransformSettings?
    let cropChanged: ([CGPoint]) -> Void
    @State private var transformDrag: (CropTransform.Handle, CGPoint, CropTransform)?
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            let crop = CropGeometry.frame(in: bounds, ratio: ratio)
            let fit = min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
            let movement = transform.panDelta(CGPoint(x: drag.width, y: drag.height))
            let layout = transform.layout(crop: crop, bounds: bounds,
                fittedSize: CGSize(width: CGFloat(image.width) * fit, height: CGFloat(image.height) * fit),
                zoom: min(16, zoom * pinch), pan: CGPoint(x: pan.width + movement.x, y: pan.height + movement.y))
            let size = layout.size
            let polygon = transform.sourcePolygon(crop: crop, bounds: bounds, imageSize: size,
                center: CGPoint(x: bounds.midX, y: bounds.midY), pan: layout.pan)
            ZStack {
                Image(decorative: image, scale: 1)
                    .allowedDynamicRange(hdr ? .high : .standard)
                    .resizable().frame(width: size.width, height: size.height)
                    .modifier(CropProjection(matrix: transform.matrix(in: crop, pan: layout.pan)))
                Canvas { context, _ in
                    var shade = Path(bounds)
                    shade.addRect(crop)
                    context.fill(shade, with: .color(.black.opacity(0.65)), style: FillStyle(eoFill: true))
                    var grid = Path(crop)
                    for fraction in [CGFloat(1.0 / 3), CGFloat(2.0 / 3)] {
                        grid.move(to: CGPoint(x: crop.minX + crop.width * fraction, y: crop.minY))
                        grid.addLine(to: CGPoint(x: crop.minX + crop.width * fraction, y: crop.maxY))
                        grid.move(to: CGPoint(x: crop.minX, y: crop.minY + crop.height * fraction))
                        grid.addLine(to: CGPoint(x: crop.maxX, y: crop.minY + crop.height * fraction))
                    }
                    context.stroke(grid, with: .color(.white), lineWidth: 1)
                    context.stroke(Path(CropTransform.controls(in: bounds)), with: .color(.white), lineWidth: 2)
                }.allowsHitTesting(false)
            }
            .frame(width: bounds.width, height: bounds.height).clipped().contentShape(Rectangle())
            .onAppear {
                if let savedTransform {
                    let restored = transform.restoredViewport(savedTransform, crop: crop, bounds: bounds,
                        fittedSize: CGSize(width: CGFloat(image.width) * fit, height: CGFloat(image.height) * fit), flippedY: false)
                    zoom = restored.zoom; pan = CGSize(width: restored.pan.x, height: restored.pan.y)
                }
            }
            .onChange(of: polygon, initial: true) { _, polygon in cropChanged(polygon) }
            .gesture(MagnifyGesture().updating($pinch) { value, state, _ in state = value.magnification }
                .onEnded { value in zoom = max(1, min(16, zoom * value.magnification)) })
            .simultaneousGesture(DragGesture(minimumDistance: 0)
                .updating($drag) { value, state, _ in
                    if CropTransform.hit(value.startLocation, in: bounds) == nil { state = value.translation }
                }
                .onChanged { value in
                    if transformDrag == nil, let handle = CropTransform.hit(value.startLocation, in: bounds) {
                        transformDrag = (handle, value.startLocation, transform)
                    }
                    if let (handle, start, original) = transformDrag {
                        transform = original.dragged(handle, from: start, to: value.location, in: bounds)
                    }
                }
                .onEnded { value in
                    if transformDrag == nil {
                        let delta = transform.panDelta(CGPoint(x: value.translation.width, y: value.translation.height))
                        let final = transform.layout(crop: crop, bounds: bounds,
                            fittedSize: CGSize(width: CGFloat(image.width) * fit, height: CGFloat(image.height) * fit),
                            zoom: zoom, pan: CGPoint(x: pan.width + delta.x, y: pan.height + delta.y))
                        pan = CGSize(width: final.pan.x, height: final.pan.y)
                    }
                    transformDrag = nil
                })
        }
    }
}
private struct CropProjection: GeometryEffect {
    var matrix: CATransform3D
    func effectValue(size: CGSize) -> ProjectionTransform {
        let centered = CATransform3DConcat(CATransform3DMakeTranslation(-size.width / 2, -size.height / 2, 0), matrix)
        return ProjectionTransform(CATransform3DConcat(centered, CATransform3DMakeTranslation(size.width / 2, size.height / 2, 0)))
    }
}
#endif
