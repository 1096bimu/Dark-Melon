import SwiftUI

struct ToneDistributionEditor: View {
    @Environment(\.resetMapping) private var defaults
    @Binding var mapping: ToneMapping
    private let keys: [WritableKeyPath<ToneContrastDistribution, Double>] = [\.black, \.shadowWidth, \.highlightWidth, \.white]
    private let labels: [LocalizedStringKey] = ["Black", "Shadows", "Highlight", "White"]

    private func value(_ key: WritableKeyPath<ToneContrastDistribution, Double>) -> Binding<Double> {
        Binding(get: { mapping.contrastDistribution[keyPath: key] }, set: {
            mapping.contrastDistribution[keyPath: key] = $0
            mapping.setAutomaticHDRTarget()
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Contrast Distribution").fontWeight(.medium)
                ControlInfo(.contrastDistribution)
            }
            FourSliderGraph(controls: keys.map(value), labels: labels, range: 0...1,
                            resetValues: keys.map { defaults.contrastDistribution[keyPath: $0] }, reversed: [3],
                            curve: mapping.neutralSDRRamp())
            HStack {
                ForEach(keys.indices, id: \.self) { index in
                    VStack(spacing: 2) {
                        Text(labels[index]).multilineTextAlignment(.center)
                            .lineLimit(1)
                        AdjustmentField(title: labels[index], value: value(keys[index]), range: 0...1,
                                        digits: 0, scale: 100, unit: "%", width: 42, unitWidth: nil)
                    }.frame(maxWidth: .infinity)
                }
            }.font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}
