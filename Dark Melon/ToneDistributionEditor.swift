import SwiftUI

/// Equal display spacing keeps the shadow controls usable at small Tone values.
/// Labels show the actual source positions; rendering uses those positions.
struct ToneDistributionEditor: View {
    @Environment(\.resetMapping) private var defaults
    @GestureState private var dragging: Int?
    @Binding var mapping: ToneMapping
    private let labels = ["Black", "Shadows", "Highlights", "White"]

    private func weight(_ index: Int) -> Binding<Double> {
        Binding(get: { exp2(mapping.contrastDistribution[index]) }, set: { value in
            mapping.contrastDistribution[index] = log2(value.clamped(to: AdjustmentLimits.distributionWeight))
            mapping.setAutomaticHDRTarget()
        })
    }

    var body: some View {
        let positions = [0, mapping.peakPosition / 2,
                         (mapping.peakPosition + mapping.white) / 2, mapping.white]
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Contrast Distribution").fontWeight(.medium)
                ControlInfo(.contrastDistribution)
            }
            GeometryReader { proxy in
                let width = max(1, proxy.size.width - 28)
                let height = max(1, proxy.size.height - 28)
                ZStack {
                    Path { path in
                        for i in 0..<4 {
                            let x = 14 + CGFloat(i) / 3 * width
                            path.move(to: CGPoint(x: x, y: 14))
                            path.addLine(to: CGPoint(x: x, y: 14 + height))
                        }
                        path.move(to: CGPoint(x: 14, y: 14 + height / 2))
                        path.addLine(to: CGPoint(x: 14 + width, y: 14 + height / 2))
                    }.stroke(EditorGraphStyle.guideColor, style: EditorGraphStyle.guide)
                    Path { path in
                        // A simple control polygon; processing retains smooth interpolation.
                        for i in 0..<4 {
                            let point = CGPoint(x: 14 + CGFloat(i) / 3 * width,
                                                y: 14 + (0.5 - mapping.contrastDistribution[i].clamped(to: -2...2) / 4) * height)
                            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                        }
                    }.stroke(EditorSliderTracks.tone, style: EditorGraphStyle.trackStroke)
                    ForEach(0..<4) { index in
                        EditorGraphHandle(isDragging: dragging == index)
                            .controlReset { weight(index).wrappedValue = exp2(defaults.contrastDistribution[index]) }
                            .position(x: 14 + CGFloat(index) / 3 * width,
                                      y: 14 + (0.5 - mapping.contrastDistribution[index].clamped(to: -2...2) / 4) * height)
                            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("toneDistribution"))
                                .updating($dragging) { _, state, _ in state = index }
                                .onChanged { drag in
                                    weight(index).wrappedValue = exp2((4 * (0.5 - (drag.location.y - 14) / height)).clamped(to: -2...2))
                                })
                            .accessibilityLabel(Text(LocalizedStringKey(labels[index])))
                            .accessibilityValue(weight(index).wrappedValue.formatted(.number.precision(.fractionLength(2))))
                            .accessibilityAdjustableAction { direction in
                                weight(index).wrappedValue *= exp2(direction == .increment ? 0.1 : -0.1)
                            }
                    }
                }.coordinateSpace(name: "toneDistribution")
            }.frame(height: 150).modifier(DisabledControlAppearance())
            HStack {
                ForEach(0..<4) { index in
                    VStack(spacing: 2) {
                        Text(LocalizedStringKey(labels[index]))
                        Text(positions[index], format: .number.precision(.fractionLength(3)))
                        AdjustmentField(title: "Contrast Distribution", value: weight(index), range: AdjustmentLimits.distributionWeight, unit: "×", width: 52)
                    }.frame(maxWidth: .infinity)
                }
            }.font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}
