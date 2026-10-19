import SwiftUI
import CoreImage

nonisolated enum RAWAdjustment: String, CaseIterable, Identifiable, Sendable {
    case luminance = "Luminance Noise Reduction"
    case color = "Color Noise Reduction"
    case sharpness = "Sharpness"
    case detail = "Detail"
    case contrast = "Local Edge Contrast"
    case moire = "Moiré Reduction"
    var id: Self { self }
    var maximum: Float { self == .detail ? 3 : 1 }
    var amount: ReferenceWritableKeyPath<CIRAWFilter, Float> {
        switch self {
        case .luminance: \.luminanceNoiseReductionAmount
        case .color: \.colorNoiseReductionAmount
        case .sharpness: \.sharpnessAmount
        case .detail: \.detailAmount
        case .contrast: \.contrastAmount
        case .moire: \.moireReductionAmount
        }
    }
    func supported(by raw: CIRAWFilter) -> Bool {
        switch self {
        case .luminance: raw.isLuminanceNoiseReductionSupported
        case .color: raw.isColorNoiseReductionSupported
        case .sharpness: raw.isSharpnessSupported
        case .detail: raw.isDetailSupported
        case .contrast: raw.isContrastSupported
        case .moire: raw.isMoireReductionSupported
        }
    }
}

nonisolated struct RAWSettings: Equatable, Sendable {
    var values: [RAWAdjustment: Float] = [:]
    var supported: Set<RAWAdjustment> = []
    var lensCorrection = false
    var supportsLensCorrection = false
    var highlightRecovery = true
    var supportsHighlightRecovery = false

    init() {}
    init(_ raw: CIRAWFilter) {
        for control in RAWAdjustment.allCases {
            values[control] = raw[keyPath: control.amount]
            if control.supported(by: raw) { supported.insert(control) }
        }
        lensCorrection = raw.isLensCorrectionEnabled
        supportsLensCorrection = raw.isLensCorrectionSupported
        highlightRecovery = raw.isHighlightRecoveryEnabled
        supportsHighlightRecovery = raw.isHighlightRecoverySupported
    }
    func apply(to raw: CIRAWFilter) {
        for control in RAWAdjustment.allCases where control.supported(by: raw) {
            if let value = values[control] { raw[keyPath: control.amount] = value }
        }
        if raw.isLensCorrectionSupported { raw.isLensCorrectionEnabled = lensCorrection }
        if raw.isHighlightRecoverySupported { raw.isHighlightRecoveryEnabled = highlightRecovery }
    }
}

struct RAWControls: View {
    @Binding var settings: RAWSettings
    let isRAW: Bool
    let commit: () -> Void
    let reset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("RAW").font(.headline)
                Spacer()
                Button("Reset RAW", action: reset).disabled(!isRAW)
            }
            if isRAW {
                Toggle("Lens Correction", isOn: Binding(get: { settings.lensCorrection }, set: {
                    settings.lensCorrection = $0; commit()
                }))
                .disabled(!settings.supportsLensCorrection)
                Toggle("Highlight Recovery", isOn: Binding(get: { settings.highlightRecovery }, set: {
                    settings.highlightRecovery = $0; commit()
                }))
                .disabled(!settings.supportsHighlightRecovery)
                ForEach(RAWAdjustment.allCases) { control in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(control.rawValue)
                            Spacer()
                            Text(settings.values[control] ?? 0, format: .number.precision(.fractionLength(2)))
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                        Slider(value: Binding(get: { settings.values[control] ?? 0 }, set: {
                            settings.values[control] = $0
                        }), in: 0...control.maximum, onEditingChanged: { editing in
                            if !editing { commit() }
                        })
                        .accessibilityLabel(control.rawValue)
                    }
                    .disabled(!settings.supported.contains(control))
                }
            } else {
                Text("Open a RAW image to adjust decoder settings.").foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .padding()
    }
}
