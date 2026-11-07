import SwiftUI
import UniformTypeIdentifiers

// This order drives the panel buttons, menu shortcuts, and Settings reference.
enum EditorPanel: String, CaseIterable, Identifiable {
    case tone = "Tone"
    case color = "Color"
    case effects = "Effects"
    case transform = "Transform"
    case raw = "RAW"
    var shellSymbol: String {
        switch self {
        case .tone: "swirl.circle.righthalf.filled"
        case .color: "camera.filters"
        case .effects: "laser.burst"
        case .transform: "crop"
        case .raw: "gearshape"
        }
    }
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
private struct LUTVisualizerFocus: FocusedValueKey { typealias Value = () -> Void }
private struct VariationExportFocus: FocusedValueKey { typealias Value = () -> Void }
private struct BatchExportFocus: FocusedValueKey {
    typealias Value = () -> Void
}
private struct CopyDevelopmentFocus: FocusedValueKey { typealias Value = () -> Void }
private struct PasteDevelopmentFocus: FocusedValueKey { typealias Value = () -> Void }
extension FocusedValues {
    var showLUTVisualizer: (() -> Void)? {
        get { self[LUTVisualizerFocus.self] }
        set { self[LUTVisualizerFocus.self] = newValue }
    }
    var variationExport: (() -> Void)? {
        get { self[VariationExportFocus.self] }
        set { self[VariationExportFocus.self] = newValue }
    }
    var copyDevelopmentSettings: (() -> Void)? {
        get { self[CopyDevelopmentFocus.self] }
        set { self[CopyDevelopmentFocus.self] = newValue }
    }
    var pasteDevelopmentSettings: (() -> Void)? {
        get { self[PasteDevelopmentFocus.self] }
        set { self[PasteDevelopmentFocus.self] = newValue }
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
    @State private var recents = RecentOpenItems.shared
    @FocusedValue(\.copyDevelopmentSettings) private var copySettings
    @FocusedValue(\.pasteDevelopmentSettings) private var pasteSettings
    private var textEditor: NSTextView? { NSApp.keyWindow?.firstResponder as? NSTextView }
    @FocusedValue(\.editorUndo) private var editUndo
    @FocusedValue(\.toggleEditorPicker) private var togglePicker
    @FocusedBinding(\.editorPanel) private var panel
    @FocusedValue(\.showLUTVisualizer) private var showLUTVisualizer
    @FocusedValue(\.variationExport) private var variationExport
    @FocusedValue(\.batchExport) private var batchExport
    @FocusedValue(\.startTutorial) private var startTutorial
    private func chooseOpen(folder: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = folder
        panel.canChooseFiles = !folder
        panel.allowsMultipleSelection = false
        if !folder { panel.allowedContentTypes = [.image, UTType(filenameExtension: "xmp") ?? .xml] }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            FileOpenRequests.shared.receive([url])
        }
    }
    private var textCanUndo: Bool { (NSApp.keyWindow?.firstResponder as? NSTextView)?.undoManager?.canUndo ?? false }
    private var textCanRedo: Bool { (NSApp.keyWindow?.firstResponder as? NSTextView)?.undoManager?.canRedo ?? false }
    var body: some Commands {
        #if DEBUG
        CommandGroup(after: .windowSize) {
            Menu("Screenshot Size") {
                ForEach(AppStoreScreenshotSize.allCases) { size in
                    Button(size.label) {
                        if let window = NSApp.keyWindow { size.apply(to: window) }
                    }
                    .disabled(panel == nil || NSApp.keyWindow.map { !size.fits($0) } != false)
                }
            }
        }
        #endif
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { textEditor?.cut(nil) }
                .keyboardShortcut("x", modifiers: .command)
                .disabled(textEditor == nil)
            Button("Copy") {
                if let textEditor { textEditor.copy(nil) } else { copySettings?() }
            }
            .keyboardShortcut("c", modifiers: .command)
            .disabled(textEditor == nil && copySettings == nil)
            Button("Paste") {
                if let textEditor { textEditor.paste(nil) } else { pasteSettings?() }
            }
            .keyboardShortcut("v", modifiers: .command)
            .disabled(textEditor == nil && pasteSettings == nil)
        }
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
        CommandGroup(replacing: .newItem) {
            Button("Open File…") { chooseOpen(folder: false) }
                .keyboardShortcut("o", modifiers: .command)
            Button("Open Folder…") { chooseOpen(folder: true) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Menu("Open Recent") {
                ForEach(recents.items) { item in
                    Button {
                        do { FileOpenRequests.shared.receive([try recents.resolve(item)]) }
                        catch {
                            let alert = NSAlert(error: error)
                            alert.runModal()
                        }
                    } label: {
                        Label(item.url.lastPathComponent, systemImage: item.folder ? "folder" : "photo")
                    }.help(item.url.path)
                }
                if recents.items.isEmpty { Text("No Recent Items") }
                Divider()
                Button("Clear Menu") { recents.clear() }.disabled(recents.items.isEmpty)
            }
        }
        CommandGroup(after: .newItem) {
            Divider()
            Button("Batch Export…") { batchExport?() }.disabled(batchExport == nil)
            SettingsLink { Text("Settings…") }
        }
        CommandGroup(replacing: .help) {
            Button("Getting Started…") {
                // SwiftUI's OpenURLAction is for web links; this guide is a bundled file.
                guard let url = Bundle.main.url(forResource: "GettingStarted", withExtension: "html"),
                      NSWorkspace.shared.open(url) else {
                    let alert = NSAlert()
                    alert.messageText = String(localized: "Could not open Getting Started")
                    alert.informativeText = String(localized: "The bundled guide could not be opened. Check that an application is available to open HTML files.")
                    alert.runModal()
                    return
                }
            }
            Button("Guided Tutorial…") { startTutorial?() }
                .disabled(startTutorial == nil)
        }
        CommandMenu("Tools") {
            Button("LUT Visualizer…") { showLUTVisualizer?() }
                .disabled(showLUTVisualizer == nil)
            Button("Variation Export…") { variationExport?() }
                .disabled(variationExport == nil)
            Divider()
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
#endif
