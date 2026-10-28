import SwiftUI
#if os(macOS)
/// Native segment actions fire even when the selected segment is clicked again.
struct BrowserPanelPicker: NSViewRepresentable {
    let selection: Int?
    let activate: (Int) -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSSegmentedControl {
        NSSegmentedControl(labels: [String(localized: "Folder"), String(localized: "Library")],
                           trackingMode: .selectOne, target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
    }
    func updateNSView(_ view: NSSegmentedControl, context: Context) {
        context.coordinator.activate = activate
        view.selectedSegment = selection ?? -1
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? { nsView.fittingSize }
    final class Coordinator: NSObject {
        var activate: ((Int) -> Void)?
        @objc func clicked(_ sender: NSSegmentedControl) { activate?(sender.selectedSegment) }
    }
}
#endif
