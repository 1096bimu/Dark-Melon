import SwiftUI

struct FilmGrainControls: View {
    @Binding var settings: FilmGrainSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Film Grain", systemImage: "film").font(.headline)
            HStack {
                Text("Size")
                AdjustmentField(title: "Size", value: $settings.size, range: 0.2...3, digits: 2, scale: 1)

            }
            Slider(value: $settings.size, in: 0.2...3) { Text("Grain size") }.labelsHidden()
            HStack {
                Text("Strength")
                AdjustmentField(title: "Strength", value: $settings.strength, range: 0...5, digits: 2, scale: 1)

            }
            Slider(value: $settings.strength, in: 0...5) { Text("Grain strength") }.labelsHidden()
            HStack {
                Text("Distribution")
                AdjustmentField(title: "Distribution", value: $settings.distribution, range: 0...1, digits: 0, scale: 100, unit: "%")

            }
            Canvas { context, size in
                var path = Path()
                for i in 0...128 {
                    let x = Double(i) / 128
                    let point = CGPoint(x: x * size.width, y: (1 - settings.weight(at: x)) * (size.height - 4) + 2)
                    if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                context.stroke(path, with: .color(.secondary), lineWidth: EditorGraphStyle.line)
            }
            .frame(height: 48)
            .accessibilityLabel("Grain distribution from shadows to highlights")
            Slider(value: $settings.distribution, in: 0...1) { Text("Grain distribution") }.labelsHidden()
            HStack { Text("Black peak"); Spacer(); Text("Midtone peak") }
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
