import SwiftUI

/// Shared numeric entry for development controls; the display scale handles percentages.
struct AdjustmentField: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    var digits = 2
    var scale = 1.0
    var unit = ""
    var width = 72.0
    var commit: () -> Void = {}
    @FocusState private var focused: Bool
    @State private var edited = false
    var body: some View {
        HStack(spacing: 3) {
            TextField(title, value: Binding(get: { value * scale }, set: {
                guard $0.isFinite else { return }
                value = ($0 / scale).clamped(to: range)
                edited = true
            }), format: .number.precision(.fractionLength(digits)))
                .labelsHidden().textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing).frame(width: width)
                .focused($focused)
                .onSubmit { finish(); focused = false }
                .onChange(of: focused) { _, active in if !active { finish() } }
            if !unit.isEmpty { Text(unit).foregroundStyle(.secondary) }
        }.font(.body.monospacedDigit()).foregroundStyle(.primary)
    }
    private func finish() {
        if edited { edited = false; commit() }
    }
}
