import SwiftUI

/// Short, accessible explanations shared by control headings and graph titles.
struct ControlInfo: View {
    enum Topic {
        case shadowBias, iso, tone, contrast, hdrGain, hdrRolloff, saturation, luminanceSaturation

        var title: String {
            switch self {
            case .shadowBias: String(localized: "Shadow Bias")
            case .iso: String(localized: "ISO")
            case .tone: String(localized: "Tone")
            case .contrast: String(localized: "Contrast")
            case .hdrGain: String(localized: "HDR Gain")
            case .hdrRolloff: String(localized: "HDR Rolloff")
            case .saturation: String(localized: "Chroma → Chroma")
            case .luminanceSaturation: String(localized: "Lightness → Chroma")
            }
        }
        var explanation: String {
            switch self {
            case .shadowBias:
                String(localized: "Crops out the signal floor that would be irrelevant in normal photos. Set to zero if you need extreme shadow detail.")
            case .iso:
                String(localized: "Equivalent to the familiar \"Exposure\" slider, here it only moves the white point and Tone sliders by proxy. Due to the property of ISO Invariance in modern sensors, using this slider is in most ways identical to changing the ISO setting in-camera during capture.")
            case .tone:
                String(localized: "Tone indicates the range of luminance that is of the most interest, usually set to skin tones, or 50% grey. Its luminance is generally protected when adjusting Contrast.")
            case .contrast:
                String(localized: "Contrast indicates the level of contrast centered around the luminance indicated by Tone.")
            case .hdrRolloff:
                String(localized: "Adjusts HDR curvature while preserving the starting tangent. Zero is straight; 100% ends flat; -100% bends upward to nearly twice the straight endpoint. HDR Gain multiplies the result and can be increased if the curves cross.")
            case .hdrGain:
                String(localized: "HDR Gain multiplies the entire HDR curve. 1× keeps the automatically calculated rendition, 2× doubles its linear brightness, and 0 turns HDR off. Tone, Contrast, and white point update the hidden HDR Target without changing this multiplier.")
            case .saturation:
                String(localized: "Four chroma multipliers joined by straight lines: zero, SDR midpoint, SDR gamut maximum, and HDR gamut maximum. The HDR endpoint follows the current HDR output ceiling. 1× is unchanged.")
            case .luminanceSaturation:
                String(localized: "Four chroma multipliers joined by straight lines at OKLCH lightness 0, 0.5, 1 (SDR white), and the cube root of the HDR output ceiling. The SDR and HDR intervals are displayed separately. 1× is unchanged.")
            }
        }
    }

    let topic: Topic
    @State private var showing = false

    init(_ topic: Topic) { self.topic = topic }

    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("About \(topic.title)")
        .help("About \(topic.title)")
        .popover(isPresented: $showing) {
            VStack(alignment: .leading, spacing: 8) {
                Text(topic.title).font(.headline)
                Text(topic.explanation)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(idealWidth: 300, maxWidth: 340, alignment: .leading)
            .presentationCompactAdaptation(.popover)
        }
    }
}
