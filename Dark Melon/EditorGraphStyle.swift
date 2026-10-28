import SwiftUI

extension EnvironmentValues {
    @Entry var controlAppearanceDimmed = false
}

/// Apply disabled opacity once, including when handles live inside a dimmed graph.
struct DisabledControlAppearance: ViewModifier {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.controlAppearanceDimmed) private var dimmed
    func body(content: Content) -> some View {
        content
            .environment(\.controlAppearanceDimmed, dimmed || !enabled)
            .opacity(!enabled && !dimmed ? 0.4 : 1)
    }
}

/// Shared visual vocabulary for interactive color graphs.
enum EditorGraphStyle {
    static let colorNames = ["R", "Y", "G", "C", "B", "M"]
    static let colorLabels: [Color] = [.red, .yellow, .green, .cyan, .blue, .pink]
    static let trackWidth: CGFloat = 5
    static let trackColor = Color.secondary.opacity(0.28)
    static let trackStroke = StrokeStyle(lineWidth: trackWidth, lineCap: .round, lineJoin: .round)
    static let line: CGFloat = 2
    static let guide = StrokeStyle(lineWidth: 1, dash: [4, 3])
    static let guideColor = Color.secondary.opacity(0.35)
    static let rim: CGFloat = 1
    static let handleSize: CGFloat = 21.6
}

/// Presentation only: the owning control supplies gesture state and can change
/// tint/strength continuously (including threshold feedback) during the drag.
struct EditorGraphHandle: View {
    var color: Color = .primary
    var selected = false
    var isDragging = false
    var tintLevel: Double = 0.85
    @Environment(\.controlResetAction) private var reset
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tint: Double { min(1, max(0, tintLevel)) }

    var body: some View {
        ZStack {
            if isDragging {
                Circle().fill(.clear)
                    .glassEffect(.clear, in: .circle)
            } else {
                Circle().fill(.white)
                    .overlay(Circle().fill(color.opacity(tint)))
            }
        }
        .frame(width: EditorGraphStyle.handleSize, height: EditorGraphStyle.handleSize)
        .overlay(Circle().strokeBorder(.primary.opacity(0.35), lineWidth: EditorGraphStyle.rim))
        .overlay(Circle().stroke(color.opacity(tint), lineWidth: EditorGraphStyle.rim)
            .padding(-3).opacity(selected ? 1 : 0))
        .shadow(color: .black.opacity(isDragging ? 0.3 : 0.15), radius: isDragging ? 4 : 1, y: isDragging ? 2 : 0)
        .scaleEffect(isDragging ? 1.15 : 1)
        .animation(reduceMotion ? nil : .smooth(duration: 0.16), value: isDragging)
        .frame(width: 28, height: 28)
        .contentShape(Circle())
        .resetInteraction(reset)
        .modifier(DisabledControlAppearance())
    }
}
