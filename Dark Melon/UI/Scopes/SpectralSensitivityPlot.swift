import SwiftUI

struct SpectralSensitivityPlot: View {
    @Environment(\.resetMapping) private var defaults
    @Binding var settings: BlackAndWhiteSettings
    let onCommit: () -> Void

    @State private var dragOrigins: [Int: Double] = [:]

    private let names = ["Red", "Yellow", "Green", "Cyan", "Blue"]
    private let wavelengths = [610, 570, 550, 490, 465]
    private let hues: [Double] = [0, 60, 120, 180, 240]
    private let horizontalPadding: CGFloat = 24
    private let verticalPadding: CGFloat = 18

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Sensitivity")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("0×–2×")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            GeometryReader { proxy in
                let size = proxy.size
                ZStack {
                    PlotGrid(centerY: yPosition(1, height: size.height))

                    Path { path in
                        for step in 0...120 {
                            let fraction = Double(step) / 120
                            let point = CGPoint(
                                x: xPosition(fraction, width: size.width),
                                y: yPosition(settings.sensitivity(at: hue(at: fraction)),
                                             height: size.height)
                            )
                            if step == 0 { path.move(to: point) }
                            else { path.addLine(to: point) }
                        }
                    }
                    .stroke(EditorGraphStyle.trackColor, style: EditorGraphStyle.trackStroke)

                    ForEach(0..<5, id: \.self) { index in
                        let value = settings.value(at: index)
                        Circle()
                            .fill(HSLColor(hue: hues[index], saturation: 1,
                                           lightness: 0.5).rgb.color)
                            .stroke(.primary, lineWidth: 2)
                            .frame(width: 20, height: 20)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                            .resetInteraction { settings.setValue(defaults.blackAndWhite.value(at: index), at: index); onCommit() }
                            .position(x: xPosition(wavelengthPosition(at: index), width: size.width),
                                      y: yPosition(value, height: size.height))
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { drag in
                                        update(index, translationY: drag.translation.height,
                                               height: size.height)
                                    }
                                    .onEnded { drag in
                                        update(index, translationY: drag.translation.height,
                                               height: size.height)
                                        dragOrigins[index] = nil
                                        onCommit()
                                    }
                            )
                            .accessibilityLabel("\(String(localized: String.LocalizationValue(names[index]))), \(wavelengths[index]) nanometers sensitivity")
                            .accessibilityValue(String(localized: "\(value.formatted(.number.precision(.fractionLength(2)))) times"))
                    }
                }
            }
            .frame(minHeight: 180)

            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    ForEach(0..<5, id: \.self) { index in
                        VStack(spacing: 2) {
                            Text("\(wavelengths[index])nm")
                            Text(String(format: "%.2f×", settings.value(at: index)))
                                .monospacedDigit()
                        }
                        .font(.caption2)
                        .fixedSize()
                        .position(x: xPosition(wavelengthPosition(at: index), width: proxy.size.width),
                                  y: 16)
                    }
                }
            }
            .frame(height: 34)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
    }

    private func xPosition(_ fraction: Double, width: CGFloat) -> CGFloat {
        horizontalPadding + fraction * max(1, width - horizontalPadding * 2)
    }

    private func wavelengthPosition(at index: Int) -> Double {
        Double(wavelengths[index] - wavelengths[4])
            / Double(wavelengths[0] - wavelengths[4])
    }

    private func hue(at fraction: Double) -> Double {
        let wavelength = Double(wavelengths[4])
            + fraction * Double(wavelengths[0] - wavelengths[4])
        for index in 0..<4 {
            let high = Double(wavelengths[index])
            let low = Double(wavelengths[index + 1])
            if wavelength >= low || index == 3 {
                return (Double(index) + (high - wavelength) / (high - low)) * 60
            }
        }
        return 240
    }

    private func yPosition(_ value: Double, height: CGFloat) -> CGFloat {
        verticalPadding + (1 - value.clamped(to: 0...2) / 2)
            * max(1, height - verticalPadding * 2)
    }

    private func update(_ index: Int, translationY: CGFloat, height: CGFloat) {
        let origin = dragOrigins[index] ?? settings.value(at: index)
        if dragOrigins[index] == nil { dragOrigins[index] = origin }
        let delta = -Double(translationY / max(1, height - verticalPadding * 2)) * 2
        var updated = settings
        updated.setValue(origin + delta, at: index)
        settings = updated
    }
}

private struct PlotGrid: View {
    let centerY: CGFloat

    var body: some View {
        Canvas { context, size in
            let border = Path(CGRect(origin: .zero, size: size))
            context.stroke(border, with: .color(.secondary.opacity(0.25)), lineWidth: 1)

            var vertical = Path()
            vertical.move(to: CGPoint(x: size.width / 2, y: 0))
            vertical.addLine(to: CGPoint(x: size.width / 2, y: size.height))
            context.stroke(vertical, with: .color(.secondary.opacity(0.15)), lineWidth: 1)

            var center = Path()
            center.move(to: CGPoint(x: 0, y: centerY))
            center.addLine(to: CGPoint(x: size.width, y: centerY))
            context.stroke(
                center,
                with: .color(.secondary.opacity(0.35)),
                style: StrokeStyle(lineWidth: 1, dash: [4, 4])
            )
        }
    }
}
