import SwiftUI

struct SplitToneHuePlot: View {
    @Binding var settings: SplitToneSettings
    let onCommit: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text("Hue")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(Int(settings.shadowHue.rounded()))°  ·  \(Int(settings.highlightHue.rounded()))°")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                let size = proxy.size
                let radius = max(1, min(size.width, size.height) * 0.5 - 14)
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                ZStack {
                    Canvas { context, _ in
                        // Use the same positive-angle convention as huePoint:
                        // 0° right, 90° up, 180° left, 270° down.
                        for step in 0..<360 {
                            let first = wheelPoint(Double(step), center: center, radius: radius)
                            let second = wheelPoint(Double(step + 1), center: center, radius: radius)
                            var segment = Path()
                            segment.move(to: first)
                            segment.addLine(to: second)
                            context.stroke(segment, with: .color(hueColor(Double(step) + 0.5)),
                                           style: StrokeStyle(lineWidth: 9, lineCap: .round))
                        }
                        for step in 0..<128 {
                            let first = settings.huePoint(at: Double(step) / 128)
                            let second = settings.huePoint(at: Double(step + 1) / 128)
                            var segment = Path()
                            segment.move(to: position(first, center: center, radius: radius))
                            segment.addLine(to: position(second, center: center, radius: radius))
                            let middle = settings.huePoint(at: (Double(step) + 0.5) / 128)
                            let color = tintColor(middle)
                            context.stroke(segment, with: .color(color),
                                           style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        }
                    }
                    Circle()
                        .fill(.white)
                        .frame(width: 6, height: 6)
                        .position(center)
                    hueHandle(settings.shadowHue, at: position(settings.huePoint(at: 0), center: center, radius: radius)) { location in
                        settings.shadowHue = angle(location, center: center)
                    }
                    hueHandle(settings.highlightHue, at: position(settings.huePoint(at: 1), center: center, radius: radius)) { location in
                        settings.highlightHue = angle(location, center: center)
                    }
                    Circle()
                        .fill(.white)
                        .frame(width: 19, height: 19)
                        .overlay(Circle().stroke(.black, lineWidth: 2))
                        .position(position(settings.huePoint(at: 0.5), center: center, radius: radius))
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("split-tone-wheel"))
                            .onChanged { value in
                                let normal = settings.hueNormal
                                let dx = Double((value.location.x - center.x) / radius)
                                let dy = -Double((value.location.y - center.y) / radius)
                                settings.midpointRadius = (dx * normal.x + dy * normal.y).clamped(to: 0...1)
                            }
                            .onEnded { _ in onCommit() })
                        .accessibilityLabel("Midtone hue bend")
                }
                .coordinateSpace(name: "split-tone-wheel")
            }
            .frame(minHeight: 120)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
    }

    private func position(_ point: SIMD2<Double>, center: CGPoint, radius: CGFloat) -> CGPoint {
        CGPoint(x: center.x + radius * point.x, y: center.y - radius * point.y)
    }

    private func wheelPoint(_ hue: Double, center: CGPoint, radius: CGFloat) -> CGPoint {
        let radians = hue * .pi / 180
        return position(SIMD2(cos(radians), sin(radians)), center: center, radius: radius)
    }

    private func hueColor(_ hue: Double) -> Color {
        HSLColor(hue: hue, saturation: 1, lightness: 0.5).rgb.color
    }

    private func tintColor(_ point: SIMD2<Double>) -> Color {
        let saturation = hypot(point.x, point.y).clamped(to: 0...1)
        let hue = atan2(point.y, point.x) * 180 / .pi
        return RGBColor.mix(
            RGBColor(red: 1, green: 1, blue: 1),
            HSLColor(hue: hue, saturation: 1, lightness: 0.5).rgb,
            amount: saturation
        ).color
    }

    private func angle(_ location: CGPoint, center: CGPoint) -> Double {
        let degrees = atan2(Double(center.y - location.y), Double(location.x - center.x)) * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }

    private func hueHandle(_ hue: Double, at point: CGPoint, onDrag: @escaping (CGPoint) -> Void) -> some View {
        Circle()
            .fill(HSLColor(hue: hue, saturation: 1, lightness: 0.5).rgb.color)
            .frame(width: 24, height: 24)
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .position(point)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("split-tone-wheel"))
                .onChanged { onDrag($0.location) }
                .onEnded { _ in onCommit() })
    }
}


struct ColorControls: View {
    @Binding var settings: ColorAdjustments
    @Binding var comparing: Bool
    var monochrome = false

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Color").font(.headline)
                Spacer()
                HoldCompareButton(comparing: $comparing)
                    .disabled(settings.isIdentity)
                Button("Reset Color") { settings = ColorAdjustments(); comparing = false }
                    .disabled(settings.isIdentity)
            }
            VerticalCurveEditor(title: "Saturation → Saturation", range: 0...2,
                                start: $settings.saturationStart, end: $settings.saturationEnd,
                                coefficient: $settings.saturationCurve, multiplier: true, info: .saturation)
                .disabled(monochrome)
            VerticalCurveEditor(title: "Luminance → Saturation", range: 0...2,
                                start: $settings.luminanceSaturationStart, end: $settings.luminanceSaturationEnd,
                                coefficient: $settings.luminanceSaturationCurve, multiplier: true,
                                lowLabel: "Low luminance", highLabel: "High luminance", info: .luminanceSaturation)
                .disabled(monochrome)
            Divider()
            HStack {
                Text("Split Tone").font(.headline)
                Spacer()
                Button("Reset") { settings.splitTone = SplitToneSettings() }
                    .disabled(settings.splitTone == SplitToneSettings())
            }
            SplitToneHuePlot(settings: $settings.splitTone, onCommit: {})
                .frame(height: 250)
            HStack {
                Label("Shadows", systemImage: "circle.lefthalf.filled")
                Spacer()
                Label("Highlights", systemImage: "circle.righthalf.filled")
            }
            .font(.caption).foregroundStyle(.secondary)
            VerticalCurveEditor(title: "Amount", range: 0...SplitToneSettings.maximumAmount,
                                start: $settings.splitTone.shadowAmount,
                                end: $settings.splitTone.highlightAmount,
                                coefficient: $settings.splitTone.amountCurveA, multiplier: false)
        }
        .padding(12)
    }
}

/// Fixed horizontal positions; only output values move while dragging.
private struct VerticalCurveEditor: View {
    let title: String
    let range: ClosedRange<Double>
    @Binding var start: Double
    @Binding var end: Double
    @Binding var coefficient: Double
    let multiplier: Bool
    var lowLabel = "Low saturation"
    var highLabel = "High saturation"
    var info: ControlInfo.Topic? = nil
    private let inset: CGFloat = 14

    private var limits: ClosedRange<Double> {
        BoundedQuadraticCurve.coefficientRange(start: start, end: end,
                                               outputRange: range, curvatureScale: 1)
    }
    private func value(_ x: Double) -> Double {
        BoundedQuadraticCurve.value(at: x, start: start, end: end, coefficient: coefficient,
                                    outputRange: range, curvatureScale: 1)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(LocalizedStringKey(title)).fontWeight(.medium)
                if let info { ControlInfo(info) }
                Spacer()
                Text(multiplier
                     ? String(format: "%.2f× · %.2f× · %.2f×", start, value(0.5), end)
                     : String(format: "%.3f", value(0.5)))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                let size = geometry.size
                ZStack {
                    Canvas { context, _ in
                        var grid = Path()
                        for i in 0...4 {
                            let t = Double(i) / 4
                            let x = inset + t * (size.width - inset * 2)
                            let y = inset + t * (size.height - inset * 2)
                            grid.move(to: CGPoint(x: x, y: inset))
                            grid.addLine(to: CGPoint(x: x, y: size.height - inset))
                            grid.move(to: CGPoint(x: inset, y: y))
                            grid.addLine(to: CGPoint(x: size.width - inset, y: y))
                        }
                        context.stroke(grid, with: .color(.secondary.opacity(0.2)), lineWidth: 1)
                        if multiplier {
                            var neutral = Path()
                            neutral.move(to: position(0, 1, size))
                            neutral.addLine(to: position(1, 1, size))
                            context.stroke(neutral, with: .color(.secondary),
                                           style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            context.draw(Text("1×").font(.caption2).foregroundStyle(.secondary),
                                         at: CGPoint(x: size.width - inset, y: size.height / 2 - 10), anchor: .trailing)
                        }
                        var curve = Path()
                        for i in 0...128 {
                            let x = Double(i) / 128
                            let p = position(x, value(x), size)
                            if i == 0 { curve.move(to: p) } else { curve.addLine(to: p) }
                        }
                        context.stroke(curve, with: .color(.accentColor), lineWidth: 2)
                    }
                    handle(0, start, size, label: multiplier ? String(localized: "\(String(localized: String.LocalizationValue(lowLabel))) multiplier") : "Shadow amount") { start = $0 }
                    handle(1, end, size, label: multiplier ? String(localized: "\(String(localized: String.LocalizationValue(highLabel))) multiplier") : "Highlight amount") { end = $0 }
                    handle(0.5, value(0.5), size, label: String(localized: "\(String(localized: String.LocalizationValue(title))) midpoint")) {
                        coefficient = (4 * ($0 - (start + end) / 2)).clamped(to: limits)
                    }
                }
                .coordinateSpace(name: title)
            }
            .frame(height: 170)
            HStack {
                Text(LocalizedStringKey(multiplier ? lowLabel : "Shadows"))
                Spacer()
                Text(LocalizedStringKey(multiplier ? highLabel : "Highlights"))
            }.font(.caption).foregroundStyle(.secondary)
        }
    }
    private func position(_ x: Double, _ y: Double, _ size: CGSize) -> CGPoint {
        CGPoint(x: inset + x * (size.width - inset * 2),
                y: inset + (1 - (y - range.lowerBound) / (range.upperBound - range.lowerBound)) * (size.height - inset * 2))
    }
    private func handle(_ x: Double, _ y: Double, _ size: CGSize, label: String,
                        update: @escaping (Double) -> Void) -> some View {
        Circle().fill(.primary).frame(width: 14, height: 14)
            .overlay(Circle().stroke(.background, lineWidth: 2))
            .frame(width: 28, height: 28).contentShape(Circle())
            .position(position(x, y, size))
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(title)).onChanged {
                let fraction = 1 - Double(($0.location.y - inset) / max(1, size.height - inset * 2))
                update((range.lowerBound + fraction * (range.upperBound - range.lowerBound)).clamped(to: range))
                coefficient = coefficient.clamped(to: limits)
            })
            .accessibilityLabel(LocalizedStringKey(label))
            .accessibilityValue(String(format: "%.3f", y))
            .accessibilityAdjustableAction { direction in
                let step = (range.upperBound - range.lowerBound) / 100
                update((y + (direction == .increment ? step : -step)).clamped(to: range))
                coefficient = coefficient.clamped(to: limits)
            }
    }
}
