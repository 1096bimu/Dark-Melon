import SwiftUI

/// Progress advances only from deliberate editor actions, never automatic adjustments.
struct EditingTutorial {
    enum Step: Int, CaseIterable {
        case tone, contrast, preview, save, export, complete
        var title: String {
            switch self {
            case .tone: String(localized: "Find the skin tones")
            case .contrast: String(localized: "Set the contrast")
            case .preview: String(localized: "Compare SDR and HDR")
            case .save: String(localized: "Save your settings")
            case .export: String(localized: "Export your photo")
            case .complete: String(localized: "Tutorial complete")
            }
        }
        var instruction: String {
            switch self {
            case .tone:
                String(localized: "In the Tone panel, drag Tone until the grey overlay highlights the neutral skin tones you want to emphasize. The overlay appears while you drag. Choose Continue when the range looks right.")
            case .contrast:
                String(localized: "Adjust Contrast until the SDR image looks good, then choose Continue. The HDR extension updates automatically from the SDR curve.")
            case .preview:
                String(localized: "Use Preview: SDR in the top bar (or H) to view HDR, then toggle back to SDR. Compare the highlight detail and overall appearance.")
            case .save:
                String(localized: "Choose Save Edits in the top bar (⌘S on Mac). This saves an XMP sidecar beside your original, so your development settings can be restored.")
            case .export:
                String(localized: "Choose Export… in the top bar (⇧⌘E on Mac), pick a format and settings, then save the exported image. JPEG or HEIF with HDR enabled can include a gain map for compatible displays.")
            case .complete:
                String(localized: "Your settings and exported image are saved. You can repeat this guide from Help → Guided Tutorial.")
            }
        }
    }

    var active = false
    private(set) var step: Step = .tone
    private(set) var fulfilled = false
    private var sawHDR = false

    mutating func start() {
        active = true
        resetForImage()
    }
    mutating func resetForImage() {
        step = .tone
        fulfilled = false
        sawHDR = false
    }
    mutating func record(_ action: Step) {
        guard active, step == action else { return }
        fulfilled = true
        if action == .export { step = .complete }
    }
    mutating func previewToggled(hdr: Bool) {
        guard active, step == .preview else { return }
        if hdr { sawHDR = true }
        else if sawHDR { fulfilled = true }
    }
    mutating func advance() {
        guard active, fulfilled, let next = Step(rawValue: step.rawValue + 1) else { return }
        step = next
        fulfilled = false
        sawHDR = false
    }
}

struct EditingTutorialGuide: View {
    let tutorial: EditingTutorial
    let imageReady: Bool
    let hdrEnabled: Bool
    let advance: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(tutorial.step.title, systemImage: "graduationcap")
                    .font(.headline)
                Spacer()
                if tutorial.step != .complete {
                    Text("\(tutorial.step.rawValue + 1) of 5")
                        .foregroundStyle(.secondary)
                }
                Button("Close Tutorial", systemImage: "xmark", action: close)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
            }
            Text(imageReady ? tutorial.step.instruction :
                    String(localized: "Open a photo with skin tones from the file browser to begin. The guide will wait while the image loads."))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if imageReady, tutorial.step == .preview, !hdrEnabled {
                Text("HDR is off. Raise HDR Gain above Off, then use the Preview toggle to compare HDR and SDR.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                if tutorial.fulfilled, tutorial.step != .complete {
                    Label("Step completed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Spacer()
                if tutorial.step == .complete {
                    Button("Done", action: close).buttonStyle(.borderedProminent)
                } else if tutorial.step != .export {
                    Button("Continue", action: advance)
                        .buttonStyle(.borderedProminent)
                        .disabled(!imageReady || !tutorial.fulfilled)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
    }
}
