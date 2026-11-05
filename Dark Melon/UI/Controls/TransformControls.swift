import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Aspect-ratio geometry shared by the transform editor and saved recipes.
nonisolated enum CropGeometry {
    nonisolated struct Ratio: Identifiable, Sendable {
        let label: String
        let value: Double
        let position: Double
        var id: Double { position }
    }

    // Keep existing saved positions 0…11; -1 adds the reciprocal of 65:24.
    static let ratios: [Ratio] = [
        Ratio(label: "24:65", value: 24.0 / 65, position: -1),
        Ratio(label: "9:21", value: 9.0 / 21, position: 0),
        Ratio(label: "9:16", value: 9.0 / 16, position: 1),
        Ratio(label: "2:3", value: 2.0 / 3, position: 2),
        Ratio(label: "3:4", value: 3.0 / 4, position: 3),
        Ratio(label: "4:5", value: 4.0 / 5, position: 4),
        Ratio(label: "1:1", value: 1, position: 5),
        Ratio(label: "5:4", value: 5.0 / 4, position: 6),
        Ratio(label: "4:3", value: 4.0 / 3, position: 7),
        Ratio(label: "3:2", value: 3.0 / 2, position: 8),
        Ratio(label: "16:9", value: 16.0 / 9, position: 9),
        Ratio(label: "21:9", value: 21.0 / 9, position: 10),
        Ratio(label: "65:24", value: 65.0 / 24, position: 11)
    ]
    static let positionRange = ratios.first!.position...ratios.last!.position

    // Equal spacing for named ratios, with continuous logarithmic interpolation between them.
    static func ratio(at position: Double) -> Double {
        let p = min(positionRange.upperBound, max(positionRange.lowerBound, position))
        let i = min(ratios.count - 2, Int(p - positionRange.lowerBound))
        let lower = ratios[i], upper = ratios[i + 1]
        let t = p - lower.position
        return exp(log(lower.value) * (1 - t) + log(upper.value) * t)
    }

    static func position(for ratio: Double) -> Double {
        guard ratio.isFinite, ratio > ratios[0].value else { return positionRange.lowerBound }
        for i in 0..<(ratios.count - 1) where ratio <= ratios[i + 1].value {
            return ratios[i].position + log(ratio / ratios[i].value) / log(ratios[i + 1].value / ratios[i].value)
        }
        return positionRange.upperBound
    }

    static func frame(in bounds: CGRect, ratio: Double) -> CGRect {
        let width = min(bounds.width, bounds.height * ratio)
        let height = width / ratio
        return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2,
                      width: width, height: height)
    }

    static func safeBounds(in bounds: CGRect, insets: CGSize) -> CGRect {
        bounds.insetBy(dx: min(insets.width, max(0, bounds.width - 1) / 2),
                       dy: min(insets.height, max(0, bounds.height - 1) / 2))
    }
}

struct TransformControls: View {
    let cropping: Bool
    @Binding var orientation: SourceOrientation
    let orientationChanged: () -> Void
    let image: CGImage?
    let polygon: [CGPoint]
    let resolution: CGSize
    let maximumResolution: CGSize
    let toggle: () -> Void
    let resetPerspective: () -> Void
    let resetRotation: () -> Void
    let resetAll: () -> Void
    var body: some View {
        EditorSection(title: "Transform") {} content: {
        VStack(alignment: .leading, spacing: 18) {
            if let image { CropOverview(image: image, polygon: polygon) }
            SourceOrientationControls(orientation: $orientation, commit: orientationChanged)
            HStack {
                transformButton
                Spacer()
                Button("Reset Transformation", action: resetAll)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .filmLock(.transform)
            resetButtons.filmLock(.transform)
            VStack(alignment: .leading, spacing: 4) {
                Text("Approx. \(Int(resolution.width)) × \(Int(resolution.height)) pixels")
                Text("Max. \(Int(maximumResolution.width)) × \(Int(maximumResolution.height)) pixels · 100% export")
            }
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private var transformButton: some View {
        Button(cropping ? "Apply" : "Transform", systemImage: "crop", action: toggle)
            .buttonStyle(.bordered).tint(cropping ? .accentColor : nil)
            .help("Adjust the transform. Double-click the preview or choose another edit panel to apply.")
    }
    private var resetButtons: some View {
        HStack {
            Button("Reset Perspective", action: resetPerspective)
            Spacer()
            Button("Reset Rotation", action: resetRotation)
        }.buttonStyle(.bordered).controlSize(.regular)
    }
}

/// Full-photo reference; only four points change while the main preview is manipulated.
private struct CropOverview: View {
    let image: CGImage
    let polygon: [CGPoint]

    var body: some View {
        GeometryReader { geometry in
            let frame = CropGeometry.frame(in: CGRect(origin: .zero, size: geometry.size), ratio: Double(image.width) / Double(image.height))
            Image(decorative: image, scale: 1)
                .resizable().frame(width: frame.width, height: frame.height)
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
                .position(x: frame.midX, y: frame.midY)
        }
        .frame(height: 180)
        .clipped()
        .accessibilityLabel("Full photo with transformed crop area")
    }
}

struct SourceOrientationControls: View {
    @Binding var orientation: SourceOrientation
    var halfTurnsOnly = false
    var commit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Orientation").font(.callout)
            HStack {
                Picker("Orientation", selection: Binding(get: { orientation.turns }, set: {
                    guard orientation.turns != $0 else { return }
                    orientation.quarterTurns = $0
                    commit()
                })) {
                    ForEach(halfTurnsOnly ? [0, 2] : [0, 1, 2, 3], id: \.self) { turn in
                        Text("\(turn * 90)°").tag(turn)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Toggle("Mirror", isOn: Binding(get: { orientation.mirrored }, set: {
                    guard orientation.mirrored != $0 else { return }
                    orientation.mirrored = $0
                    commit()
                }))
                .fixedSize()
                .help("Flip this exposure horizontally.")
            }
        }
        .filmLock(.sourceOrientation)
    }
}

/// The center marker selects a continuous ratio; only a label click snaps.
struct CropRatioControls: View {
    @Environment(\.isEnabled) private var enabled
    @Binding var position: Double
    @State private var dragStart: Double?
    private let step: CGFloat = 64
    private var minimum: Double { CropGeometry.positionRange.lowerBound }
    private var maximum: Double { CropGeometry.positionRange.upperBound }

    private func setPosition(_ value: Double) {
        guard enabled else { return }
        position = min(maximum, max(minimum, value))
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(CropGeometry.ratios) { ratio in
                    Button {
                        guard dragStart == nil else { return }
                        position = ratio.position
                    } label: {
                        Text(ratio.label)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(abs(position - ratio.position) < 0.001 ? .primary : .secondary)
                            .frame(width: step, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .offset(x: geometry.size.width / 2 - step / 2 - CGFloat(position - minimum) * step)
            .frame(width: geometry.size.width, height: 36, alignment: .leading)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Capsule().fill(.secondary).frame(width: 18, height: 2).allowsHitTesting(false)
            }
            .simultaneousGesture(DragGesture(minimumDistance: 3)
                .onChanged { value in
                    if dragStart == nil { dragStart = position }
                    setPosition((dragStart ?? position) - Double(value.translation.width / step))
                }
                .onEnded { _ in DispatchQueue.main.async { dragStart = nil } })
            #if os(macOS)
            .background(RatioWheelInput { delta in
                setPosition(position + Double(delta / step))
            })
            #endif
            .clipped()
        }
        .frame(height: 36)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Aspect Ratio")
        .accessibilityValue(CropGeometry.ratio(at: position).formatted(.number.precision(.fractionLength(3))))
        .accessibilityAdjustableAction { direction in
            setPosition(position + (direction == .increment ? 0.1 : -0.1))
        }
    }
}

#if os(macOS)
private struct RatioWheelInput: NSViewRepresentable {
    let scroll: (CGFloat) -> Void
    func makeNSView(context: Context) -> WheelView { WheelView() }
    func updateNSView(_ view: WheelView, context: Context) { view.scroll = scroll }
    static func dismantleNSView(_ view: WheelView, coordinator: ()) { view.stopMonitoring() }

    final class WheelView: NSView {
        var scroll: (CGFloat) -> Void = { _ in }
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.window, !self.isHiddenOrHasHiddenAncestor,
                      self.visibleRect.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
                let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
                self.scroll(-delta * (event.hasPreciseScrollingDeltas ? 1 : 8))
                return nil
            }
        }
        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
#endif

#if !os(macOS)
/// The mobile preview has no AppKit viewport; use native SwiftUI touch gestures.
struct MobileCropPreview: View {
    let image: CGImage
    let hdr: Bool
    let ratio: Double
    @Binding var transform: CropTransform
    let savedTransform: TransformSettings?
    let cropChanged: ([CGPoint]) -> Void
    var safeInsets = CGSize.zero
    @State private var transformDrag: (CropTransform.Handle, CGPoint, CropTransform)?
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            let safeBounds = CropGeometry.safeBounds(in: bounds, insets: safeInsets)
            let crop = CropGeometry.frame(in: safeBounds, ratio: ratio)
            let fit = min(safeBounds.width / CGFloat(image.width), safeBounds.height / CGFloat(image.height))
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
                    .overlay {
                        Canvas { context, _ in
                            let shade = transform.outsideCropPath(crop: crop, bounds: bounds, imageSize: size,
                                center: CGPoint(x: bounds.midX, y: bounds.midY), pan: layout.pan)
                            context.fill(Path(shade), with: .color(.black.opacity(0.65)), style: FillStyle(eoFill: true))
                        }.allowsHitTesting(false)
                    }
                    .modifier(CropProjection(matrix: transform.matrix(in: crop, pan: layout.pan)))
                Canvas { context, _ in
                    var grid = Path(crop)
                    for fraction in [CGFloat(1.0 / 3), CGFloat(2.0 / 3)] {
                        grid.move(to: CGPoint(x: crop.minX + crop.width * fraction, y: crop.minY))
                        grid.addLine(to: CGPoint(x: crop.minX + crop.width * fraction, y: crop.maxY))
                        grid.move(to: CGPoint(x: crop.minX, y: crop.minY + crop.height * fraction))
                        grid.addLine(to: CGPoint(x: crop.maxX, y: crop.minY + crop.height * fraction))
                    }
                    context.stroke(grid, with: .color(.white), lineWidth: 1)
                    context.stroke(Path(CropTransform.controls(in: safeBounds)), with: .color(.white), lineWidth: 2)
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
                    if CropTransform.hit(value.startLocation, in: safeBounds) == nil { state = value.translation }
                }
                .onChanged { value in
                    if transformDrag == nil, let handle = CropTransform.hit(value.startLocation, in: safeBounds) {
                        transformDrag = (handle, value.startLocation, transform)
                    }
                    if let (handle, start, original) = transformDrag {
                        transform = original.dragged(handle, from: start, to: value.location, in: safeBounds)
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


/// Uses the library's name so renaming a LUT is reflected here as well.
struct ActiveLUTControls: View {
    @Binding var mapping: ToneMapping
    @State private var dimension: Int?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("LUT").font(.headline)
            if let id = mapping.lutID {
                HStack {
                    Text(EditLibrary.shared.entries.first(where: { $0.lutID == id })?.name ?? "LUT")
                        .lineLimit(2)
                    Spacer()
                    Button("Remove") { mapping.lutID = nil; mapping.lutStrength = 1 }
                }
                if let dimension {
                    Text("\(dimension) × \(dimension) × \(dimension)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text("Strength")
                    Spacer()
                    AdjustmentField(title: "Strength", value: $mapping.lutStrength, range: 0...1, digits: 2)
                }
                EditorSlider(value: $mapping.lutStrength, in: 0...1) { Text("Strength") }
                    .labelsHidden().controlReset { mapping.lutStrength = 1 }
            }
        }
        .padding(16)
        .modifier(ShellSection())
        .task(id: mapping.lutID) {
            dimension = nil
            guard let id = mapping.lutID else { return }
            let size = await Task.detached { LUTStore.shared.cube(for: id)?.dimension }.value
            guard !Task.isCancelled else { return }
            dimension = size
        }
    }
}
