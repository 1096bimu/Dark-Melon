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
    var resetValues = [1.0, 1.0, 1.0, 1.0]
    private var controls: [Binding<Double>] { [$start, $middle, $sdr, $hdr] }
    private var labels: [String] { ["0", "SDR ½", "SDR", "HDR"] }
    private var levels: [Double] { [0, sdrMaximum/2, sdrMaximum, sdrMaximum*cbrt(hdrMax)] }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(LocalizedStringKey(title)).fontWeight(.medium)
                ControlInfo(info)
            }
            FourSliderGraph(
                controls: hdrMax > 1 ? controls : Array(controls.prefix(3)) + [.constant(sdr)],
                labels: labels.map { LocalizedStringKey("\(title) \($0)") }, range: 0...2,
                resetValues: resetValues, disabled: hdrMax > 1 ? [] : [3])

            HStack {
                ForEach(0..<4) { index in
                    VStack(spacing: 2) {
                        Text(labels[index])
                        Text(levels[index],format: .number.precision(.fractionLength(3)))
                        AdjustmentField(title: "Chroma", value: controls[index], range: AdjustmentLimits.chroma, unit: "×", width: 52, unitWidth: nil)
                            .disabled(index == 3 && hdrMax <= 1)
                    }.frame(maxWidth: .infinity)
                }
            }.font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}
