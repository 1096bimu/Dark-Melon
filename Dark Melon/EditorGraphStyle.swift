import SwiftUI

/// Shared visual vocabulary for interactive color graphs.
enum EditorGraphStyle {
    static let colorNames = ["R", "Y", "G", "C", "B", "M"]
    static let colorLabels: [Color] = [.red, .yellow, .green, .cyan, .blue, .pink]
    static let line: CGFloat = 2
    static let guide = StrokeStyle(lineWidth: 1, dash: [4, 3])
    static let guideColor = Color.secondary.opacity(0.35)
    static let rim: CGFloat = 1
    static let handleSize: CGFloat = 18
}

struct EditorGraphHandle: View {
    var color: Color = .white
    var selected = false
    var body: some View {
        Circle().fill(color)
            .overlay(Circle().strokeBorder(.black.opacity(0.85), lineWidth: 2))
            .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1).padding(2))
            .frame(width: EditorGraphStyle.handleSize, height: EditorGraphStyle.handleSize)
            .overlay(Circle().stroke(Color.accentColor, lineWidth: 2).padding(-3).opacity(selected ? 1 : 0))
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            .frame(width: 28, height: 28).contentShape(Circle())
    }
}
