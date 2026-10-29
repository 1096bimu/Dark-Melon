import SwiftUI

struct ColorControls: View {
    @Environment(\.resetMapping) private var defaults
    @Environment(\.lockedFilmItems) private var lockedItems
    @Binding var settings: ColorAdjustments
    @Binding var vertices: [OKLabVertexAdjustment]
    var monochrome = false
    var hdrMax = 1.0
    var colorSpace = ProcessingColorSpace.sRGB

    var body: some View {
        VStack(spacing: 16) {
            Group {
                if !monochrome {
                    ChromaCurveEditor(title: "Chroma → Chroma", start: $settings.saturationStart,
                        middle: $settings.saturationMid, sdr: $settings.saturationEnd, hdr: $settings.saturationHDR,
                        sdrMaximum: OKLCHGamut.maxima[colorSpace]!, hdrMax: hdrMax, info: .saturation, resetValues: [defaults.color.saturationStart, defaults.color.saturationMid, defaults.color.saturationEnd, defaults.color.saturationHDR]).filmLock(.chromaCurve)
                    ChromaCurveEditor(title: "Lightness → Chroma", start: $settings.luminanceSaturationStart,
                        middle: $settings.luminanceSaturationMid, sdr: $settings.luminanceSaturationEnd,
                        hdr: $settings.luminanceSaturationHDR, sdrMaximum: 1, hdrMax: hdrMax, info: .luminanceSaturation, resetValues: [defaults.color.luminanceSaturationStart, defaults.color.luminanceSaturationMid, defaults.color.luminanceSaturationEnd, defaults.color.luminanceSaturationHDR]).filmLock(.lightnessChromaCurve)
                    Divider()
                }
            }
            HStack {
                Text("Split Tone").font(.headline)
                Spacer()
            }
            SplitToneGradientEditor(settings: $settings.splitTone, space: colorSpace, ceiling: hdrMax).filmLock(.splitTone)



        }
        .padding(12)
    }

}


struct ColorPanelHeader: View {
    @Environment(\.resetMapping) private var defaults
    @Environment(\.lockedFilmItems) private var lockedItems
    @Binding var settings: ColorAdjustments
    @Binding var vertices: [OKLabVertexAdjustment]
    @Binding var comparing: Bool
    var body: some View {
        HStack {
            Text("Color").font(.headline)
            Spacer()
            HoldCompareButton(comparing: $comparing)
                .disabled(settings.isIdentity && vertices.allSatisfy(\.isIdentity))
            Button("Reset Color") { settings = defaults.color; vertices = defaults.vertexWarp; comparing = false }
                .disabled(!lockedItems.isDisjoint(with: Set(PasteItem.colorItems)) || (settings == defaults.color && vertices == defaults.vertexWarp))
        }
    }
}
