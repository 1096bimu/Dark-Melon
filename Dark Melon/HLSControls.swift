import SwiftUI

struct HLSControls: View {
    @Binding var adjustments: [HLSAdjustment]
    @Binding var comparing: Bool
    @Binding var blackAndWhite: BlackAndWhiteSettings
    private let names = ["Red", "Yellow", "Green", "Cyan", "Blue", "Magenta"]
    private let colors: [Color] = [.red, .yellow, .green, .cyan, .blue, Color(red: 1, green: 0, blue: 1)]

    var body: some View {
        VStack(spacing: 18) {
            Toggle("Black & White", isOn: $blackAndWhite.isEnabled)
                .toggleStyle(.switch)
            HStack {
                Text("HLS").font(.headline)
                Spacer()
                HoldCompareButton(comparing: $comparing)
                    .disabled(adjustments.allSatisfy(\.isIdentity) && blackAndWhite.isIdentity)
                Button("Reset HLS") {
                    adjustments = Array(repeating: HLSAdjustment(), count: 6)
                    blackAndWhite = BlackAndWhiteSettings()
                }
                    .disabled(adjustments.allSatisfy(\.isIdentity) && blackAndWhite.isIdentity)
            }
            if blackAndWhite.isEnabled {
                SpectralSensitivityPlot(settings: $blackAndWhite, onCommit: {})
                    .frame(height: 280)
            } else {
            ForEach(0..<6) { index in
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Circle().fill(colors[index]).frame(width: 10, height: 10)
                        Text(names[index]).font(.headline)
                        Spacer()
                        Button("Reset") { adjustments[index] = HLSAdjustment() }
                            .disabled(adjustments[index].isIdentity)
                    }
                    HueToneCurve(adjustment: $adjustments[index], color: colors[index], baseHue: Double(index) * 60)
                    HStack {
                        Text("Saturation")
                        Text("\(adjustments[index].saturation, format: .number.precision(.fractionLength(2)))×")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: $adjustments[index].saturation, in: 0...2) { Text("\(names[index]) saturation") }
                        .labelsHidden()
                    HStack {
                        Text("Lightness")
                        Text(String(format: "%+.0f%%", adjustments[index].lightness * 25))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: $adjustments[index].lightness, in: -1...1) { Text("\(names[index]) lightness") }
                        .labelsHidden()
                }
                if index < 5 { Divider() }
            }
            }
        }
        .padding(12)
    }
}

private struct HueToneCurve: View {
    @Binding var adjustment: HLSAdjustment
    let color: Color
    let baseHue: Double
    @Namespace private var coordinates

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text("Hue")
                Spacer()
                Text(String(format: "%+.0f° · %+.0f° · %+.0f°", adjustment.shadowHue, adjustment.midtoneHue, adjustment.highlightHue))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                let size = geometry.size
                ZStack {
                    Canvas { context, _ in
                        var grid = Path()
                        for i in 0...2 {
                            let p = point(i, 0, size)
                            grid.move(to: CGPoint(x: p.x, y: 12))
                            grid.addLine(to: CGPoint(x: p.x, y: size.height - 12))
                        }
                        grid.move(to: point(0, 0, size)); grid.addLine(to: point(2, 0, size))
                        context.stroke(grid, with: .color(.secondary.opacity(0.3)), lineWidth: 1)
                        var curve = Path()
                        curve.move(to: point(0, adjustment.shadowHue, size))
                        curve.addLine(to: point(1, adjustment.midtoneHue, size))
                        curve.addLine(to: point(2, adjustment.highlightHue, size))
                        context.stroke(curve, with: .color(color), lineWidth: 2)
                    }
                    handle(0, $adjustment.shadowHue, size, "Shadow hue")
                    handle(1, $adjustment.midtoneHue, size, "Midtone hue")
                    handle(2, $adjustment.highlightHue, size, "Highlight hue")
                }
                .coordinateSpace(name: coordinates)
            }
            .frame(height: 110)
            HStack {
                Text("Shadows"); Spacer(); Text("Midtones"); Spacer(); Text("Highlights")
            }.font(.caption2).foregroundStyle(.secondary)
        }
    }
    private func point(_ index: Int, _ value: Double, _ size: CGSize) -> CGPoint {
        CGPoint(x: 12 + Double(index) / 2 * (size.width - 24),
                y: 12 + (30 - value) / 60 * (size.height - 24))
    }
    private func handle(_ index: Int, _ value: Binding<Double>, _ size: CGSize, _ label: String) -> some View {
        // Match Alchemy's exaggerated visual feedback; processing retains the actual shift.
        Circle().fill(HSLColor(hue: baseHue + value.wrappedValue * 2,
                               saturation: 0.5, lightness: 0.5).rgb.color)
            .frame(width: 14, height: 14)
            .overlay(Circle().stroke(.background, lineWidth: 2))
            .frame(width: 28, height: 28).contentShape(Circle())
            .position(point(index, value.wrappedValue, size))
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(coordinates)).onChanged {
                value.wrappedValue = (30 - Double(($0.location.y - 12) / max(1, size.height - 24)) * 60).clamped(to: -30...30)
            })
            .accessibilityLabel(label)
            .accessibilityValue(String(format: "%+.0f degrees", value.wrappedValue))
            .accessibilityAdjustableAction { direction in
                value.wrappedValue = (value.wrappedValue + (direction == .increment ? 1 : -1)).clamped(to: -30...30)
            }
    }
}
