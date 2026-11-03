import SwiftUI

enum EditorSectionLayout {
  static let width: CGFloat = 380
  static let minimumShellWidth: CGFloat = 2 * width + 320 + 48
  static let inset: CGFloat = 8
  static let spacing: CGFloat = 16
  static let panelCornerRadius: CGFloat = 18
  static let sectionCornerRadius: CGFloat = panelCornerRadius - inset
}

/// Shared editor section chrome. Content supplies controls only.
struct EditorSection<Actions: View, Content: View>: View {
  let title: LocalizedStringKey
  @ViewBuilder var actions: Actions
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 8) {
        Text(title).font(.headline)
        Spacer(minLength: 8)
        actions.buttonStyle(.bordered).controlSize(.regular)
      }
      content
    }
    .padding(16)
    .modifier(ShellSection())
  }
}

/// Content rests inside equal margins while the viewport fills the panel.
struct InspectorScrollView<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            content
        }
        .contentMargins(.all, EditorSectionLayout.inset, for: .scrollContent)
        .frame(width: EditorSectionLayout.width)
    }
}
