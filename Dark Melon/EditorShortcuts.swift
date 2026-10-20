import SwiftUI

// This order drives the segmented picker, menu shortcuts, and Settings reference.
enum EditorPanel: String, CaseIterable, Identifiable {
    case tone = "Tone"
    case color = "Color"
    case hls = "HLS"
    case effects = "Effects"
    case raw = "RAW"
    var id: Self { self }
    var shortcut: String? {
        guard let index = Self.allCases.firstIndex(of: self), index < 10 else { return nil }
        return String((index + 1) % 10)
    }
}

enum EditorPickerTool { case whiteBalance }

private struct EditorPickerFocus: FocusedValueKey {
    typealias Value = (EditorPickerTool) -> Void
}
private struct EditorPanelFocus: FocusedValueKey {
    typealias Value = Binding<EditorPanel>
}
private struct TutorialFocus: FocusedValueKey {
    typealias Value = () -> Void
}
private struct BatchExportFocus: FocusedValueKey {
    typealias Value = () -> Void
}
extension FocusedValues {
    var toggleEditorPicker: ((EditorPickerTool) -> Void)? {
        get { self[EditorPickerFocus.self] }
        set { self[EditorPickerFocus.self] = newValue }
    }
    var startTutorial: (() -> Void)? {
        get { self[TutorialFocus.self] }
        set { self[TutorialFocus.self] = newValue }
    }
    var batchExport: (() -> Void)? {
        get { self[BatchExportFocus.self] }
        set { self[BatchExportFocus.self] = newValue }
    }
    var editorPanel: Binding<EditorPanel>? {
        get { self[EditorPanelFocus.self] }
        set { self[EditorPanelFocus.self] = newValue }
    }
}

#if os(macOS)
struct EditorCommands: Commands {
    @FocusedValue(\.toggleEditorPicker) private var togglePicker
    @FocusedBinding(\.editorPanel) private var panel
    @FocusedValue(\.batchExport) private var batchExport
    @FocusedValue(\.startTutorial) private var startTutorial
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Divider()
            Button("Batch Export…") { batchExport?() }.disabled(batchExport == nil)
            SettingsLink { Text("Settings…") }
        }
        CommandGroup(replacing: .help) {
            Button("Guided Tutorial…") { startTutorial?() }
                .disabled(startTutorial == nil)
        }
        CommandMenu("Tools") {
            Button("White Balance Picker") { togglePicker?(.whiteBalance) }
                .keyboardShortcut("w", modifiers: [])
                .disabled(togglePicker == nil)
        }
        CommandMenu("Panels") {
            ForEach(EditorPanel.allCases) { item in
                if let shortcut = item.shortcut {
                    Button(item.rawValue) { panel = item }
                        .keyboardShortcut(KeyEquivalent(Character(shortcut)), modifiers: [])
                        .disabled(panel == nil)
                } else {
                    Button(item.rawValue) { panel = item }
                        .disabled(panel == nil)
                }
            }
        }
    }
}

struct EditorSettingsView: View {
    var body: some View {
        Form {
            Section("Keyboard Shortcuts") {
                shortcut("Copy development settings", "⌘C")
                shortcut("Paste development settings…", "⌘V")
                shortcut("Save development settings", "⌘S")
                shortcut("Export…", "⇧⌘E")
                shortcut("Toggle HDR preview", "H")
                shortcut("Toggle file browser", "F")
                shortcut("Toggle white balance picker", "W")
            }
            Section("Panels") {
                ForEach(EditorPanel.allCases) { panel in
                    if let key = panel.shortcut { shortcut(panel.rawValue, key) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 600)
    }
    private func shortcut(_ title: String, _ keys: String) -> some View {
        LabeledContent(title) { Text(keys).monospaced().foregroundStyle(.secondary) }
    }
}
#endif
