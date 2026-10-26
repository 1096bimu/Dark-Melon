import SwiftUI

// This order drives the segmented picker, menu shortcuts, and Settings reference.
enum EditorPanel: String, CaseIterable, Identifiable {
    case tone = "Tone"
    case color = "Color"
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
private struct ImageInfoFocus: FocusedValueKey {
    typealias Value = Binding<Bool>
}
private struct TutorialFocus: FocusedValueKey {
    typealias Value = () -> Void
}
private struct BatchExportFocus: FocusedValueKey {
    typealias Value = () -> Void
}
extension FocusedValues {
    var imageInfoVisible: Binding<Bool>? {
        get { self[ImageInfoFocus.self] }
        set { self[ImageInfoFocus.self] = newValue }
    }
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
    @Environment(\.openURL) private var openURL
    @FocusedValue(\.editorUndo) private var editUndo
    @FocusedValue(\.toggleEditorPicker) private var togglePicker
    @FocusedBinding(\.editorPanel) private var panel
    @FocusedBinding(\.imageInfoVisible) private var imageInfoVisible
    @FocusedValue(\.batchExport) private var batchExport
    @FocusedValue(\.startTutorial) private var startTutorial
    private var textCanUndo: Bool { (NSApp.keyWindow?.firstResponder as? NSTextView)?.undoManager?.canUndo ?? false }
    private var textCanRedo: Bool { (NSApp.keyWindow?.firstResponder as? NSTextView)?.undoManager?.canRedo ?? false }
    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button(editUndo?.undoTitle ?? String(localized: "Undo")) {
                if let text = NSApp.keyWindow?.firstResponder as? NSTextView, let manager = text.undoManager, manager.canUndo {
                    manager.undo()
                } else { editUndo?.undo() }
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!(editUndo?.canUndo ?? false) && !textCanUndo)
            Button(editUndo?.redoTitle ?? String(localized: "Redo")) {
                if let text = NSApp.keyWindow?.firstResponder as? NSTextView, let manager = text.undoManager, manager.canRedo {
                    manager.redo()
                } else { editUndo?.redo() }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!(editUndo?.canRedo ?? false) && !textCanRedo)
        }
        CommandGroup(after: .newItem) {
            Divider()
            Button("Batch Export…") { batchExport?() }.disabled(batchExport == nil)
            SettingsLink { Text("Settings…") }
        }
        CommandGroup(replacing: .help) {
            Button("Getting Started…") {
                if let url = Bundle.main.url(forResource: "GettingStarted", withExtension: "html") {
                    openURL(url)
                }
            }
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
            Divider()
            Toggle("Image Info", isOn: Binding(get: { imageInfoVisible ?? true }, set: { imageInfoVisible = $0 }))
                .keyboardShortcut("i", modifiers: [])
                .disabled(imageInfoVisible == nil)
        }
    }
}

struct EditorSettingsView: View {
    @State private var section = 0
    @AppStorage(ExportMetadata.effectiveISOPreferenceKey) private var effectiveISO = true
    @AppStorage(HDRScreenSaver.preferenceKey) private var screenSaver = false
    @AppStorage("showHueTwister") private var showHueTwister = false
    @AppStorage(RAWSettings.maximizeRangePreferenceKey) private var alwaysMaximizeRAWRange = false
    @AppStorage(ScopeGradient.preferenceKey) private var gradient = ScopeGradient.inferno
    var body: some View {
        VStack(spacing: 0) {
            Picker("Settings section", selection: $section) {
                Text("Settings").tag(0)
                Text("Shortcuts").tag(1)
                Text("Licenses").tag(2)
            }
            .pickerStyle(.segmented)
            .padding()
            if section == 0 { preferencesView }
            else if section == 1 { shortcutsView }
            else { licenseView }
        }
        .frame(width: 460, height: 600)
    }

    private var preferencesView: some View {
        Form {
            Section("Preview") {
                Toggle("Screen Saver", isOn: $screenSaver)
                    .help("Fade the HDR preview to SDR when the app loses focus or after one minute without mouse or keyboard input. Activity restores HDR without changing the selected preview mode.")
                Text("Dims the screen from HDR brightness to avoid burn-in.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Export") {
                Toggle("Effective ISO", isOn: $effectiveISO)
                    .help("Replace the exported capture ISO with the effective ISO shown by the ISO slider. The original file is unchanged.")
                Text("Record the effective ISO in exports, taking exposure adjustments into account, rather than the capture ISO.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("RAW") {
                Toggle("Always maximize RAW range", isOn: $alwaysMaximizeRAWRange)
                    .help("Run Max Range automatically for RAW files without saved or pending edits.")
                Text("Automatically fit the maximum RAW highlight data into the editing space when opening new files.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Color Scope") {
                Toggle("HUE Twister", isOn: $showHueTwister)
                    .help("Show darker/lighter hue controls. Saved adjustments remain active when hidden.")
                Picker("Density gradient", selection: $gradient) {
                    ForEach(ScopeGradient.allCases) { item in
                        Text(item.displayName).tag(item)
                    }
                }
                LinearGradient(gradient: gradient.legendGradient, startPoint: .leading, endPoint: .trailing)
                    .frame(height: 16).clipShape(RoundedRectangle(cornerRadius: 4))
                HStack {
                    Text("Low density")
                    Spacer()
                    Text("High density")
                }.font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    private var shortcutsView: some View {
        Form {
            Section("Keyboard Shortcuts") {
                shortcut("Undo", "⌘Z")
                shortcut("Redo", "⇧⌘Z")
                shortcut("Copy development settings", "⌘C")
                shortcut("Paste development settings…", "⌘V")
                shortcut("Save development settings", "⌘S")
                shortcut("Export…", "⇧⌘E")
                shortcut("Original", "Hold C")
                shortcut("Toggle HDR preview", "H")
                shortcut("Image Info", "I")
                shortcut("Folder", "F")
                shortcut("Library", "L")
                shortcut("Previous / next file", "← / →")
                shortcut("Select All", "⌘A")
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
