import SwiftUI

/// Readout/editing of the RGB gains; shared by RAW and ordinary RGB images.
struct RGBGainControls: View {
  @Binding var gains: WhiteBalance
  var body: some View {
    HStack(spacing: 6) {
      Text("R")
      AdjustmentField(
        title: "Red gain", value: $gains.red, range: 0.000001...10000, digits: 3, width: 60,
        unitWidth: nil)
      Text("G")
      AdjustmentField(
        title: "Green gain", value: $gains.green, range: 0.000001...10000, digits: 3, width: 60,
        unitWidth: nil)
      Text("B")
      AdjustmentField(
        title: "Blue gain", value: $gains.blue, range: 0.000001...10000, digits: 3, width: 60,
        unitWidth: nil)
    }.filmLock(.rgbWhiteBalance)
  }
}

/// Decoder WB controls, placed below RGB gains for a RAW or in the selected
/// source's RAW panel for a double exposure. Never shown for ordinary RGB files.
struct ColorTemperatureControls: View {
  @Environment(\.resetMapping) private var defaults
  @Environment(\.lockedFilmItems) private var lockedItems
  @Binding var whiteBalance: RAWWhiteBalance?
  let rgbGains: WhiteBalance
  var monochrome = false
  var reset: (() -> Void)?
  var convert: (() -> Void)?
  var commit: () -> Void = {}
  var preset: ((Float) -> Void)?

  private func setPreset(_ temperature: Float) {
    if let preset {
      preset(temperature)
      return
    }
    guard var balance = whiteBalance else { return }
    balance.temperature = temperature
    balance.tint = 0
    whiteBalance = balance
    commit()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Text("Color Temperature").font(.headline)
        Spacer()
        if monochrome, let reset { Button("Reset WB", action: reset) }
        if !monochrome, let convert {
          Button("Convert to WB", action: convert)
            .disabled(
              rgbGains == WhiteBalance() || lockedItems.contains(.rgbWhiteBalance)
                || lockedItems.contains(.rawWhiteBalance))
        }
      }
      HStack(spacing: 8) {
        Spacer()
        Button("D") { setPreset(5500) }.help("5500 K · Tint 0").filmLock(.rawWhiteBalance)
        Button("T") { setPreset(3200) }.help("3200 K · Tint 0").filmLock(.rawWhiteBalance)
      }
      HStack {
        Text("Temperature")
        Spacer()
        AdjustmentField(
          title: "Temperature",
          value: Binding(
            get: { Double(whiteBalance?.temperature ?? 6500) },
            set: { whiteBalance?.temperature = Float($0) }),
          range: 2000...50000, digits: 0, unit: "K", commit: commit
        ).filmLock(.rawWhiteBalance)
      }
      EditorSlider(
        value: Binding(
          get: { Double(whiteBalance?.temperature ?? 6500) },
          set: {
            whiteBalance?.temperature = Float($0)
          }), in: 2000...10000,
        onEditingChanged: { editing in
          if !editing { commit() }
        }
      ).filmLock(.rawWhiteBalance)
        .controlReset {
          if let wb = defaults.rawWhiteBalance { whiteBalance?.temperature = wb.temperature }
        }
        .editorSliderTrack(EditorSliderTracks.temperature)
      HStack {
        Text("Tint")
        Spacer()
        AdjustmentField(
          title: "Tint",
          value: Binding(
            get: { Double(whiteBalance?.tint ?? 0) },
            set: { whiteBalance?.tint = Float($0) }),
          range: -150...150, digits: 2, commit: commit
        ).filmLock(.rawWhiteBalance)
      }
      EditorSlider(
        value: Binding(
          get: { Double(whiteBalance?.tint ?? 0) },
          set: {
            whiteBalance?.tint = Float($0)
          }), in: -50...50,
        onEditingChanged: { editing in
          if !editing { commit() }
        }
      ).filmLock(.rawWhiteBalance)
        .controlReset { if let wb = defaults.rawWhiteBalance { whiteBalance?.tint = wb.tint } }
        .editorSliderTrack(EditorSliderTracks.tint)
    }.font(.callout.monospacedDigit())
  }
}
