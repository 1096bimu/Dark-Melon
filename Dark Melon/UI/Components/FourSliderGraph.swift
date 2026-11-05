import SwiftUI

/// Shared vertical sliders, with either a sampled curve or a control polygon.
struct FourSliderGraph: View {
    let controls: [Binding<Double>]
    let labels: [LocalizedStringKey]
    let range: ClosedRange<Double>
    let resetValues: [Double]
    var reversed: Set<Int> = []
    var disabled: Set<Int> = []
    var curve: [Double]? = nil
    @GestureState private var dragging: Int?
    @Namespace private var coordinateSpace

    private func fraction(_ index: Int) -> Double {
        let value = ((controls[index].wrappedValue - range.lowerBound) / (range.upperBound - range.lowerBound)).clamped(to: 0...1)
        return reversed.contains(index) ? 1 - value : value
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width - 28)
            let height = max(1, proxy.size.height - 28)
            let intervals = CGFloat(max(1, controls.count - 1))
            ZStack {
                Path { path in
                    for index in controls.indices {
                        let x = 14 + CGFloat(index) / intervals * width
                        path.move(to: CGPoint(x: x, y: 14))
                        path.addLine(to: CGPoint(x: x, y: 14 + height))
                    }
                    path.move(to: CGPoint(x: 14, y: 14 + height / 2))
                    path.addLine(to: CGPoint(x: 14 + width, y: 14 + height / 2))
                }.stroke(EditorGraphStyle.guideColor, style: EditorGraphStyle.guide)
                Path { path in
                    if let curve, curve.count > 1 {
                        for index in curve.indices {
                            let point = CGPoint(x: 14 + CGFloat(index) / CGFloat(curve.count - 1) * width,
                                                y: 14 + (1 - curve[index].clamped(to: 0...1)) * height)
                            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                        }
                    } else {
                        for index in controls.indices {
                            let point = CGPoint(x: 14 + CGFloat(index) / intervals * width,
                                                y: 14 + (1 - fraction(index)) * height)
                            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                        }
                    }
                }.stroke(EditorGraphStyle.trackColor, style: EditorGraphStyle.trackStroke)
                ForEach(controls.indices, id: \.self) { index in
                    EditorGraphHandle(isDragging: dragging == index)
                        .controlReset { controls[index].wrappedValue = resetValues[index] }
                        .position(x: 14 + CGFloat(index) / intervals * width,
                                  y: 14 + (1 - fraction(index)) * height)
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(coordinateSpace))
                            .updating($dragging) { _, state, _ in state = index }
                            .onChanged { drag in
                                var value = (1 - (drag.location.y - 14) / height).clamped(to: 0...1)
                                if reversed.contains(index) { value = 1 - value }
                                controls[index].wrappedValue = range.lowerBound + value * (range.upperBound - range.lowerBound)
                            })
                        .accessibilityLabel(Text(labels[index]))
                        .accessibilityValue(controls[index].wrappedValue.formatted(.number.precision(.fractionLength(2))))
                        .accessibilityAdjustableAction { direction in
                            let delta = (range.upperBound - range.lowerBound) / 100
                            controls[index].wrappedValue = (controls[index].wrappedValue + (direction == .increment ? delta : -delta)).clamped(to: range)
                        }
                        .disabled(disabled.contains(index))
                }
            }.coordinateSpace(name: coordinateSpace)
        }.frame(height: 150).modifier(DisabledControlAppearance())
    }
}
