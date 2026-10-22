import SwiftUI

/// SDR and HDR intervals have separate labeled widths so all four handles remain usable.
struct ChromaCurveEditor: View {
    let title: String
    @Binding var start: Double
    @Binding var middle: Double
    @Binding var sdr: Double
    @Binding var hdr: Double
    let sdrMaximum: Double
    let hdrMax: Double
    let info: ControlInfo.Topic
    private var controls: [Binding<Double>] { [$start, $middle, $sdr, $hdr] }
    private var labels: [String] { ["0", "SDR ½", "SDR", "HDR"] }
    private var levels: [Double] { [0, sdrMaximum/2, sdrMaximum, sdrMaximum*cbrt(hdrMax)] }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(LocalizedStringKey(title)).fontWeight(.medium)
                ControlInfo(info)
            }
            GeometryReader { proxy in
                let width = max(1, proxy.size.width-28)
                let height = max(1, proxy.size.height-28)
                let values = [start, middle, sdr, hdrMax > 1 ? hdr : sdr]
                ZStack {
                    Path { path in
                        for i in 0..<4 {
                            let x = 14 + CGFloat(i)/3*width
                            path.move(to: CGPoint(x: x, y: 14))
                            path.addLine(to: CGPoint(x: x, y: 14+height))
                        }
                        path.move(to: CGPoint(x: 14,y: 14+height/2))
                        path.addLine(to: CGPoint(x: 14+width,y: 14+height/2))
                    }.stroke(EditorGraphStyle.guideColor, style: EditorGraphStyle.guide)
                    Path { path in
                        for i in 0..<4 {
                            let p = CGPoint(x: 14+CGFloat(i)/3*width,y: 14+(1-values[i]/2)*height)
                            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                        }
                    }.stroke(.tint,lineWidth: EditorGraphStyle.line)
                    ForEach(0..<4) { index in
                        EditorGraphHandle()
                            .position(x: 14+CGFloat(index)/3*width,y: 14+(1-values[index]/2)*height)
                            .gesture(DragGesture(minimumDistance: 0,coordinateSpace: .named(title)).onChanged {
                                controls[index].wrappedValue = (2*(1-($0.location.y-14)/height)).clamped(to: 0...2)
                            })
                            .accessibilityLabel("\(title) \(labels[index])")
                            .accessibilityValue(values[index].formatted(.number.precision(.fractionLength(2))))
                            .accessibilityAdjustableAction { direction in
                                controls[index].wrappedValue = (values[index]+(direction == .increment ? 0.02 : -0.02)).clamped(to: 0...2)
                            }
                            .disabled(index == 3 && hdrMax <= 1)
                            .opacity(index == 3 && hdrMax <= 1 ? 0.35 : 1)
                    }
                }.coordinateSpace(name: title)
            }.frame(height: 150)
            HStack {
                ForEach(0..<4) { index in
                    VStack(spacing: 2) {
                        Text(labels[index])
                        Text(levels[index],format: .number.precision(.fractionLength(3)))
                        AdjustmentField(title: "Chroma", value: controls[index], range: 0...2, unit: "×", width: 52)
                            .disabled(index == 3 && hdrMax <= 1)
                    }.frame(maxWidth: .infinity)
                }
            }.font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}
