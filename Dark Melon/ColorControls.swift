import SwiftUI

struct ColorControls: View {
    @Binding var settings: ColorAdjustments
    @Binding var vertices: [OKLabVertexAdjustment]
    @Binding var comparing: Bool
    var monochrome = false
    var hdrMax = 1.0
    var colorSpace = ProcessingColorSpace.sRGB

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Color").font(.headline)
                Spacer()
                HoldCompareButton(comparing: $comparing)
                    .disabled(settings.isIdentity && vertices.allSatisfy(\.isIdentity))
                Button("Reset Color") { settings = ColorAdjustments(); vertices = OKLabVertexWarp.defaults; comparing = false }
                    .disabled(settings.isIdentity && vertices.allSatisfy(\.isIdentity))
            }
            ChromaCurveEditor(title: "Chroma → Chroma", start: $settings.saturationStart,
                middle: $settings.saturationMid, sdr: $settings.saturationEnd, hdr: $settings.saturationHDR,
                sdrMaximum: OKLCHGamut.maxima[colorSpace]!, hdrMax: hdrMax, info: .saturation)
                .disabled(monochrome)
            ChromaCurveEditor(title: "Lightness → Chroma", start: $settings.luminanceSaturationStart,
                middle: $settings.luminanceSaturationMid, sdr: $settings.luminanceSaturationEnd,
                hdr: $settings.luminanceSaturationHDR, sdrMaximum: 1, hdrMax: hdrMax, info: .luminanceSaturation)
                .disabled(monochrome)
            Divider()
            OKLabVertexControls(controls: $vertices, space: colorSpace)
            Divider()
            HStack {
                Text("Split Tone").font(.headline)
                Spacer()
                Button("Reset") { settings.splitTone = SplitToneSettings() }
                    .disabled(settings.splitTone == SplitToneSettings())
            }
            SplitToneGradientEditor(settings: $settings.splitTone, space: colorSpace, ceiling: hdrMax)


        }
        .padding(12)
    }

}
