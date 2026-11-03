import SwiftUI
import UniformTypeIdentifiers

/// The editor's preview, floating panels, and toolbars share one layout.
struct GlassEditorShell<Preview: View, Browser: View, Controls: View, Pending: View, LeftToolbar: View, Toolbar: View, RightToolbar: View>: View {
    @AppStorage("glassEffectsEnabled") private var glassEffects = true
    let browserVisible: Bool
    let panelVisible: Bool
    let current: URL?
    let resolution: CGSize
    let fileSize: Int64?
    var metadata: CameraMetadata? = nil
    var folderPosition: String? = nil
    var hdrEnabled = false
    var showsBottomPill = true
    #if os(macOS)
    @State private var displaySupportsEDR: Bool?
    #endif
    var comparisonMode: Binding<ComparisonMode>? = nil
    var cropRatioPosition: Binding<Double>? = nil
    var dismissBrowser: (() -> Void)? = nil
    @ViewBuilder var preview: Preview
    @ViewBuilder var browser: Browser
    @ViewBuilder var controls: Controls
    @ViewBuilder var pending: Pending
    @ViewBuilder var leftToolbar: LeftToolbar
    @ViewBuilder var toolbar: Toolbar
    @ViewBuilder var rightToolbar: RightToolbar

    private var previewInsets: EdgeInsets {
        guard glassEffects, comparisonMode == nil else { return EdgeInsets() }
        return EdgeInsets(top: 0,
            leading: browserVisible && !panelVisible ? EditorSectionLayout.width + 12 : 0,
            bottom: 0, trailing: panelVisible ? EditorSectionLayout.width + 12 : 0)
    }

    @ViewBuilder private var previewContent: some View {
        if glassEffects, comparisonMode == nil { preview }
        else { preview.clipped() }
    }

    var body: some View {
        previewContent
            .environment(\.previewPanelInsets, previewInsets)
            // Reserve only one side: the edit panel takes precedence over browsing.
            .padding(.leading, browserVisible && !panelVisible ? EditorSectionLayout.width + 12 : 0)
            .padding(.trailing, panelVisible ? EditorSectionLayout.width + 12 : 0)
            .overlay {
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 12) {
                        leftToolbar.padding(.horizontal, 16).modifier(ShellPill())
                            .floatingBrowserInteractionArea()
                        if browserVisible {
                            browser
                                .environment(\.shellPanelContent, true)
                                .scrollContentBackground(.hidden)
                                .padding(EditorSectionLayout.inset)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .modifier(ShellGlass())
                                .floatingBrowserInteractionArea()
                        } else {
                            Spacer(minLength: 0)
                        }
                    }
                    .frame(width: EditorSectionLayout.width)
                    .frame(maxHeight: .infinity)

                    VStack(spacing: 12) {
                        HStack(alignment: .top, spacing: 12) {
                            pending
                            toolbar.padding(.horizontal, 16).modifier(ShellPill())
                                #if os(macOS)
                                .background(HDRCapabilityProbe(value: $displaySupportsEDR))
                                #endif
                            #if os(macOS)
                            EditorStatusPill(hdrWarning: hdrEnabled && displaySupportsEDR == false)
                            #endif
                        }.zIndex(1)
                        Spacer(minLength: 12)
                        if showsBottomPill {
                            if let cropRatioPosition {
                                CropRatioControls(position: cropRatioPosition)
                                    .filmLock(.transform)
                                    .frame(maxWidth: 350)
                                    .modifier(ShellPill())
                            } else if let comparisonMode {
                                ComparisonModePicker(selection: comparisonMode)
                                    .frame(maxWidth: 350)
                                    .padding(.horizontal, 12)
                                    .modifier(ShellPill())
                            } else {
                                PreviewInfoPill(current: current, resolution: resolution, fileSize: fileSize,
                                                metadata: metadata, position: folderPosition)
                            }
                        }
                    }
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)

                    VStack(spacing: 12) {
                        rightToolbar.padding(.horizontal, 16).modifier(ShellPill())
                        if panelVisible {
                            controls
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .modifier(ShellGlass())
                        } else {
                            Spacer(minLength: 0)
                        }
                    }
                    .frame(width: EditorSectionLayout.width)
                    .frame(maxHeight: .infinity)
                }
                .padding(12)
            }
            .modifier(FloatingBrowserDismissal(enabled: browserVisible && panelVisible,
                                               dismiss: { dismissBrowser?() }))
    }

}

extension EnvironmentValues {
    @Entry var shellPanelContent = false
    @Entry var previewPanelInsets = EdgeInsets()
}

struct ShellPill: ViewModifier {
    var height: CGFloat? = 36
    var tint: Double = 0.2
    @AppStorage("glassEffectsEnabled") private var glassEffects = true
    func body(content: Content) -> some View {
        let pill = content.frame(height: height).modifier(PreviewHoverBlocking())
        if glassEffects {
            pill
                .glassEffect(.regular.tint(.black.opacity(tint)), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        } else {
            pill.background(.black, in: Capsule())
        }
    }
}

private struct ShellGlass: ViewModifier {
    @AppStorage("glassEffectsEnabled") private var glassEffects = true
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: EditorSectionLayout.panelCornerRadius)
        let panel = content.clipShape(shape).modifier(PreviewHoverBlocking())
        if glassEffects {
            panel
                .background(.black.opacity(0.22), in: shape)
                .glassEffect(.regular, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.25), radius: 16, y: 5)
        } else {
            panel.background(.black, in: shape)
        }
    }
}

struct ShellSection: ViewModifier {
    @AppStorage("glassEffectsEnabled") private var glassEffects = true
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.black.opacity(glassEffects ? 0.15 : 1), in: RoundedRectangle(cornerRadius: EditorSectionLayout.sectionCornerRadius))
            .overlay(RoundedRectangle(cornerRadius: EditorSectionLayout.sectionCornerRadius).strokeBorder(.white.opacity(0.06), lineWidth: 0.5))
    }
}


struct ShellToolbarItem: ViewModifier {
    func body(content: Content) -> some View {
        content.frame(width: 32, height: 28).contentShape(Rectangle())
    }
}

struct ShellToolbarDivider: View {
    var body: some View {
        Divider().frame(width: 1, height: 16).padding(.horizontal, 4)
    }
}

/// Selection belongs to the active inspector, independently of keyboard focus.
struct ShellPanelButtonStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .frame(width: 32, height: 28)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.white.opacity(configuration.isPressed ? 0.26 : selected ? 0.18 : 0))
            }
            .contentShape(Rectangle())
    }
}

/// An anchored expansion uses the same surfaces as the rest of the shell.
struct PendingEditsControl: View {
    let entries: [PendingEdits.Entry]
    let current: URL?
    let busy: Bool
    let open: (URL) -> Void
    let save: () -> Void
    let ignore: () -> Void
    @State private var expanded = false

    var body: some View {
        if !entries.isEmpty {
            Button {
                expanded.toggle()
            } label: {
                Image(systemName: "square.and.arrow.down.badge.clock")
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .modifier(ShellPill())
            .accessibilityLabel(Text("Unsaved edits (\(entries.count))"))
            .accessibilityValue(expanded ? "Open" : "Closed")
            .help("Unsaved edits (\(entries.count))")
            .overlay(alignment: .topLeading) {
                if expanded {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Unsaved edits (\(entries.count))").font(.headline)
                            Spacer()
                            Button { expanded = false } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain).accessibilityLabel("Close")
                        }
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(entries) { entry in
                                    Button {
                                        expanded = false
                                        open(entry.url)
                                    } label: {
                                        Text(entry.url.lastPathComponent)
                                            .lineLimit(1).truncationMode(.middle)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.vertical, 4)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(entry.url == current?.standardizedFileURL ? Color.accentColor : .primary)
                                    .help(entry.url.path)
                                }
                            }
                        }.frame(height: min(240, CGFloat(entries.count) * 30))
                        HStack(spacing: 8) {
                            Button("Save", action: save)
                            Button("Ignore", action: ignore)
                        }.buttonStyle(.bordered).controlSize(.regular).disabled(busy)
                    }
                    .padding(16).frame(width: 280)
                    .modifier(ShellGlass())
                    .padding(.top, 48)
                }
            }
            .onDisappear { expanded = false }
        }
    }
}

/// Extend only the native image surface; the surrounding preview keeps its layout size.
struct PreviewPanelOverflow: ViewModifier {
    @Environment(\.previewPanelInsets) private var insets
    func body(content: Content) -> some View {
        content.padding(.leading, -insets.leading).padding(.trailing, -insets.trailing)
    }
}
