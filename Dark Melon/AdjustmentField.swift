import SwiftUI

/// Keep partial numbers out of the rendering state until entry is complete.
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
    @State private var draft = ""
    @State private var edited = false

    private var format: FloatingPointFormatStyle<Double> {
        .number.grouping(.never).precision(.fractionLength(digits))
    }

    var body: some View {
        HStack(spacing: 3) {
            TextField(title, text: Binding(get: { draft }, set: {
                draft = $0
                edited = true
            }))
                .labelsHidden().textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing).frame(width: width)
                .focused($focused)
                .onAppear { refresh() }
                .onSubmit { finish(); focused = false }
                .onChange(of: focused) { _, active in
                    if active { refresh() } else { finish() }
                }
                .onChange(of: value) { _, _ in
                    if !focused { refresh() }
                }
            if !unit.isEmpty { Text(unit).foregroundStyle(.secondary) }
        }.font(.body.monospacedDigit()).foregroundStyle(.primary)
    }

    private func refresh() {
        draft = (value * scale).formatted(format)
    }

    private func finish() {
        let wasEdited = edited
        edited = false
        if wasEdited, let parsed = try? Double(draft, format: format), parsed.isFinite {
            value = (parsed / scale).clamped(to: range)
            refresh()
            commit()
        } else {
            refresh()
        }
    }
}
