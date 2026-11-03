import SwiftUI

struct ColorControls: View {
  @Environment(\.resetMapping) private var defaults
  @Environment(\.lockedFilmItems) private var lockedItems
  @Binding var settings: ColorAdjustments
  @Binding var vertices: [OKLabVertexAdjustment]
  @Binding var comparing: Bool
  var monochrome = false
  var hdrMax = 1.0
  var colorSpace = ProcessingColorSpace.sRGB

  var body: some View {
    EditorSection(title: "Color") {
      HoldCompareButton(comparing: $comparing)
      Button("Reset") {
        settings = defaults.color
        comparing = false
      }.disabled(!lockedItems.isDisjoint(with: [.vertices, .colorChrome, .chromaCurve, .lightnessChromaCurve, .splitTone]))
    } content: {
      VStack(alignment: .leading, spacing: 18) {
        HStack {
          Toggle(
            "Monochrome",
            isOn: Binding(
              get: { settings.monochrome },
              set: { enabled in
                settings.monochrome = enabled
                OKLabVertexWarp.setMonochrome(enabled, controls: &vertices)
              })
          ).toggleStyle(.switch).filmLock(.vertices)
          Spacer()
          HStack(spacing: 6) {
            Text("Color Chrome")
            ControlInfo(.colorChrome)
            Toggle("Color Chrome", isOn: $settings.colorChrome)
              .labelsHidden()
              .toggleStyle(.switch)
              .filmLock(.colorChrome)
              .disabled(settings.monochrome)
          }
        }

        Group {
          if !monochrome {
            ChromaCurveEditor(
              title: "Chroma → Chroma", start: $settings.saturationStart,
              middle: $settings.saturationMid, sdr: $settings.saturationEnd,
              hdr: $settings.saturationHDR,
              sdrMaximum: OKLCHGamut.maxima[colorSpace]!, hdrMax: hdrMax, info: .saturation,
              resetValues: [
                defaults.color.saturationStart, defaults.color.saturationMid,
                defaults.color.saturationEnd, defaults.color.saturationHDR,
              ]
            ).filmLock(.chromaCurve)
            ChromaCurveEditor(
              title: "Lightness → Chroma", start: $settings.luminanceSaturationStart,
              middle: $settings.luminanceSaturationMid, sdr: $settings.luminanceSaturationEnd,
              hdr: $settings.luminanceSaturationHDR, sdrMaximum: 1, hdrMax: hdrMax,
              info: .luminanceSaturation,
              resetValues: [
                defaults.color.luminanceSaturationStart, defaults.color.luminanceSaturationMid,
                defaults.color.luminanceSaturationEnd, defaults.color.luminanceSaturationHDR,
              ]
            ).filmLock(.lightnessChromaCurve)
          }
        }
        HStack {
          Text("Split Tone").font(.headline)
          Spacer()
        }
        SplitToneGradientEditor(settings: $settings.splitTone, space: colorSpace, ceiling: hdrMax)
          .filmLock(.splitTone)

      }
    }
  }

}
