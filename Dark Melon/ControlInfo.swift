import SwiftUI

/// Short, accessible explanations shared by control headings and graph titles.
struct ControlInfo: View {
    enum Topic {
        case shadowBias, tone, contrast, hdrGain, hdrRolloff, autoTones, saturation, luminanceSaturation

        var title: String {
            switch self {
            case .shadowBias: "Shadow Bias"
            case .tone: "Tone"
            case .contrast: "Contrast"
            case .hdrGain: "HDR Gain"
            case .hdrRolloff: "HDR Rolloff"
            case .autoTones: "Auto Tones"
            case .saturation: "Saturation → Saturation"
            case .luminanceSaturation: "Luminance → Saturation"
            }
        }
        var explanation: String {
            switch self {
            case .shadowBias:
                "Crops out the signal floor that would be irrelevant in normal photos. Set to zero if you need extreme shadow detail."
            case .tone:
                "Tone indicates the range of luminance that is of the most interest, usually set to skin tones, or 50% grey. Its luminance is generally protected when adjusting Contrast."
            case .contrast:
                "Contrast indicates the level of contrast centered around the luminance indicated by Tone."
            case .hdrRolloff:
                "Lowers HDR white below the calculated target while preserving the starting tangent. Zero keeps a straight continuation; 100% ends flat. HDR Gain multiplies the result and can be increased if the curves cross."
            case .hdrGain:
                "HDR Gain multiplies the entire HDR curve. 1× keeps the automatically calculated rendition, 2× doubles its linear brightness, and 0 turns HDR off. Tone, Contrast, and white point update the hidden HDR Target without changing this multiplier."
            case .autoTones:
                "Auto Tones attempts to adjust the other settings based on a user-selected shade of interest, usually set to skin tones. Select shadows for lighter skin tones and highlights for darker skin tones."
            case .saturation:
                "This lets you set multipliers to saturation for different levels of input saturation. A traditional “vibrance” slider is equivalent to moving the midpoint in this graph. And a traditional “Saturation” slider is equivalent to moving the right end point of this graph."
            case .luminanceSaturation:
                "Commonly used in video production, this graph lets you modify the saturation of pixels based on their luminance. For example the midpoint tends to control the saturation of skin tones."
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
