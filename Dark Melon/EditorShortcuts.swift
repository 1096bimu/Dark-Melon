import SwiftUI

// This order drives the segmented picker, menu shortcuts, and Settings reference.
enum EditorPanel: String, CaseIterable, Identifiable {
    case tone = "Tone"
    case color = "Color"
    case hls = "HLS"
    case effects = "Effects"
    case transform = "Transform"
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
                    Button(LocalizedStringKey(item.rawValue)) { panel = item }
                        .keyboardShortcut(KeyEquivalent(Character(shortcut)), modifiers: [])
                        .disabled(panel == nil)
                } else {
                    Button(LocalizedStringKey(item.rawValue)) { panel = item }
                        .disabled(panel == nil)
                }
            }
        }
    }
}

struct EditorSettingsView: View {
    @State private var licenses = false
    var body: some View {
        VStack(spacing: 0) {
            Picker("Settings section", selection: $licenses) {
                Text("Shortcuts").tag(false)
                Text("Licenses").tag(true)
            }
            .pickerStyle(.segmented)
            .padding()
            if licenses { licenseView } else { shortcutsView }
        }
        .frame(width: 460, height: 600)
    }

    private var shortcutsView: some View {
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
    }
    private var licenseView: some View {
        Form {
            Section("Dark Melon") {
                Text("GNU General Public License v3.0 (GPL-3.0-only)")
                Text("Copyright © 2026 Dark Melon contributors. Distributed without warranty.")
                    .foregroundStyle(.secondary)
                Link("Source code", destination: URL(string: "https://github.com/1096bimu/Dark-Melon")!)
            }
            Section("Cinegrain 2") {
                Text("Film grain adapted from cinegrain2 by mr-berndt.")
                Text("Copyright © 2026 mr-berndt. GPL-3.0-or-later.")
                    .foregroundStyle(.secondary)
                Link("Cinegrain 2 source", destination: URL(string: "https://github.com/mr-berndt/cinegrain2")!)
            }
            Section("GNU GPL v3 — full license") {
                if let url = Bundle.main.url(forResource: "Cinegrain2-LICENSE", withExtension: "txt"),
                   let text = try? String(contentsOf: url, encoding: .utf8) {
                    Text(text).font(.caption).textSelection(.enabled)
                } else {
                    Link("Read GNU GPL v3", destination: URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func shortcut(_ title: String, _ keys: String) -> some View {
        LabeledContent(LocalizedStringKey(title)) { Text(keys).monospaced().foregroundStyle(.secondary) }
    }
}
#endif
