import SwiftUI

#if os(macOS)
struct EditorSettingsView: View {
    private enum Category: String, CaseIterable, Identifiable {
        case interface, editor, infoPill, shortcuts, licenses
        var id: Self { self }
        var title: String {
            switch self {
            case .interface: String(localized: "Interface")
            case .editor: String(localized: "Editor")
            case .infoPill: String(localized: "Info Pill")
            case .shortcuts: String(localized: "Shortcuts")
            case .licenses: String(localized: "Licenses")
            }
        }
        var symbol: String {
            switch self {
            case .interface: "rectangle.3.group"
            case .editor: "slider.horizontal.3"
            case .infoPill: "info.circle"
            case .shortcuts: "keyboard"
            case .licenses: "doc.text"
            }
        }
    }
    @State private var category: Category? = .interface
    @State private var language = AppLanguage.selection()
    @AppStorage(ExportMetadata.effectiveISOPreferenceKey) private var effectiveISO = true
    @AppStorage(HDRScreenSaver.preferenceKey) private var screenSaver = false
    @AppStorage("glassEffectsEnabled") private var glassEffects = true
    @AppStorage(InfoPillField.preferenceKey) private var infoPillFields = InfoPillField.standard
    @AppStorage("autoTurbo") private var autoTurbo = "never"
    @AppStorage("previewMouseControls") private var mouseControls = false
    @AppStorage("previewReverseMouseScroll") private var reverseMouseScroll = false
    @AppStorage("showHueTwister") private var showHueTwister = false
    @AppStorage("showISOSlider") private var showISOSlider = false
    @AppStorage("showContrastDistribution") private var showContrastDistribution = true
    @AppStorage("showAdvancedRAWControls") private var showAdvancedRAWControls = false
    @AppStorage(RAWSettings.maximizeRangePreferenceKey) private var alwaysMaximizeRAWRange = false
    @AppStorage(ScopeGradient.preferenceKey) private var gradient = ScopeGradient.inferno
    var body: some View {
        HStack(spacing: 0) {
            List(selection: $category) {
                Section {
                    ForEach([Category.interface, .editor, .infoPill]) { category in
                        Label(category.title, systemImage: category.symbol).tag(category)
                    }
                }
                Section {
                    ForEach([Category.shortcuts, .licenses]) { category in
                        Label(category.title, systemImage: category.symbol).tag(category)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .padding(.top, 36)
            .frame(width: 180)
            .background(.bar)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text("Settings")
                    .font(.headline)
                    .frame(height: 36)
                    .padding(.horizontal, 24)
                Text((category ?? .interface).title)
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                detailContent
            }
            .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea(.container, edges: .top)
        .toggleStyle(EditorToggleStyle())
        .preferredColorScheme(.dark)
        .frame(width: 800, height: 600)
    }

    @ViewBuilder private var detailContent: some View {
        switch category ?? .interface {
        case .interface: interfaceView
        case .editor: editorView
        case .infoPill: infoPillView
        case .shortcuts: shortcutsView
        case .licenses: licenseView
        }
    }

    private var interfaceView: some View {
        Form {
            Section {
                Picker("Language", selection: $language) {
                    Text("System").tag(AppLanguage.system)
                    ForEach(AppLanguage.available, id: \.self) { identifier in
                        Text(verbatim: AppLanguage.name(for: identifier)).tag(identifier)
                    }
                }
                .onChange(of: language) { _, language in AppLanguage.select(language) }
            } footer: {
                Text("Language changes take effect after you quit and reopen the app. System follows your preferred system language.")
            }
            Section {
                Toggle("Glass Effects", isOn: $glassEffects)
                Picker("Navigation Mode", selection: $mouseControls) {
                    Text("Touchpad").tag(false)
                    Text("Mouse").tag(true)
                }.pickerStyle(.segmented)
                Toggle("Reverse Scroll Direction", isOn: $reverseMouseScroll)
                    .disabled(!mouseControls)
                Toggle("Screen Saver", isOn: $screenSaver)
                    .help("Fade the HDR preview to SDR when the app loses focus or after one minute without mouse or keyboard input. Activity restores HDR without changing the selected preview mode.")
            } footer: {
                Text("Dims the screen from HDR brightness to avoid burn-in.")
            }
            Section("Color Scope") {
                Picker("Scope Gradient", selection: $gradient) {
                    ForEach(ScopeGradient.allCases) { item in
                        Text(item.displayName).tag(item)
                    }
                }
                LinearGradient(gradient: gradient.legendGradient, startPoint: .leading, endPoint: .trailing)
                    .frame(height: 16).clipShape(Capsule())
            }
            Section {
                Picker("Auto Turbo", selection: $autoTurbo) {
                    Text("Never").tag("never")
                    Text("Plugged In").tag("plugged")
                    Text("Always").tag("always")
                }
            } footer: {
                Text("Turbo prepares RAW photos in the background so they open faster. Choose when it turns on automatically. It uses more processing power and energy while preparing photos.")
            }
        }.formStyle(.grouped)
    }

    private var editorView: some View {
        Form {
            Section {
                Toggle("Always Maximize RAW Range", isOn: $alwaysMaximizeRAWRange)
                    .help("Run Max Range automatically for RAW files without saved or pending edits.")
            } footer: {
                Text("Automatically fit the maximum RAW highlight data into the editing space when opening new files.")
            }
            Section {
                Toggle("ISO Slider", isOn: $showISOSlider)
                Toggle("Contrast Distribution", isOn: $showContrastDistribution)
                Toggle("Hue Twister", isOn: $showHueTwister)
                Toggle("Advanced RAW Sliders", isOn: $showAdvancedRAWControls)
                    .help("Show Lens Correction, Highlight Recovery, Offset, noise reduction, sharpness, detail, local edge contrast, and moiré reduction.")
            } header: {
                Text("Controls")
            } footer: {
                Text("Hiding controls does not change their values or affect processing, copy/paste, or Film Lock.")
            }
            Section {
                Toggle("Effective ISO", isOn: $effectiveISO)
                    .help("Replace the exported capture ISO with the effective ISO shown by the ISO slider. The original file is unchanged.")
            } header: {
                Text("Export")
            } footer: {
                Text("Record the effective ISO in exports, taking exposure adjustments into account, rather than the capture ISO.")
            }
        }.formStyle(.grouped)
    }

    private var infoPillView: some View {
        Form {
            Section {
                ForEach(InfoPillField.allCases) { field in
                    Toggle(field.title, isOn: Binding(
                        get: { field.isVisible(in: infoPillFields) },
                        set: { infoPillFields = field.settingVisible($0, in: infoPillFields) }))
                }
            } footer: {
                Text("Turning everything off hides the info pill. Comparison and crop controls remain available.")
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
            Section("GNU GPL v3 — full license") {
                if let url = Bundle.main.url(forResource: "GPL-3.0", withExtension: "txt"),
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
