import SwiftUI
import CoreImage

nonisolated enum RAWAdjustment: String, CaseIterable, Identifiable, Codable, Sendable {
    case exposure = "Exposure"
    case shadowBias = "Shadow Bias"
    case luminance = "Luminance Noise Reduction"
    case color = "Color Noise Reduction"
    case sharpness = "Sharpness"
    case detail = "Detail"
    case contrast = "Local Edge Contrast"
    case moire = "Moiré Reduction"
    var id: Self { self }
    var minimum: Float {
        switch self { case .exposure: -5; default: 0 }
    }
    var maximum: Float {
        switch self { case .exposure, .shadowBias: 5; case .detail: 3; default: 1 }
    }
    var amount: ReferenceWritableKeyPath<CIRAWFilter, Float> {
        switch self {
        case .exposure: \.exposure
        case .shadowBias: \.shadowBias
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
        case .exposure, .shadowBias: true
        case .luminance: raw.isLuminanceNoiseReductionSupported
        case .color: raw.isColorNoiseReductionSupported
        case .sharpness: raw.isSharpnessSupported
        case .detail: raw.isDetailSupported
        case .contrast: raw.isContrastSupported
        case .moire: raw.isMoireReductionSupported
        }
    }
}

nonisolated struct RAWSettings: Codable, Equatable, Sendable {
    var values: [RAWAdjustment: Float] = [:]
    var supported: Set<RAWAdjustment> = []
    var lensCorrection = false
    var supportsLensCorrection = false
    var highlightRecovery = true
    var supportsHighlightRecovery = false

    private enum CodingKeys: String, CodingKey { case values, lensCorrection, highlightRecovery }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.values == rhs.values && lhs.lensCorrection == rhs.lensCorrection && lhs.highlightRecovery == rhs.highlightRecovery
    }

    /// Capabilities always belong to the destination decoder, not the saved recipe.
    func resolved(using defaults: Self) -> Self {
        var result = defaults
        result.values.merge(values) { _, saved in saved }
        result.lensCorrection = lensCorrection
        result.highlightRecovery = highlightRecovery
        return result
    }

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
    @Binding var offset: Double
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
                            Text(LocalizedStringKey(control.rawValue))
                            if control == .shadowBias { ControlInfo(.shadowBias) }
                            Spacer()
                            Text(settings.values[control] ?? 0, format: .number.precision(.fractionLength(2)))
                                .foregroundStyle(.secondary).monospacedDigit()
                            if control == .exposure { Text("EV").foregroundStyle(.secondary) }
                        }
                        Slider(value: Binding(get: { settings.values[control] ?? 0 }, set: {
                            settings.values[control] = $0
                        }), in: control.minimum...control.maximum, onEditingChanged: { editing in
                            if !editing { commit() }
                        })
                        .accessibilityLabel(LocalizedStringKey(control.rawValue))
                    }
                    .disabled(!settings.supported.contains(control))
                    if control == .shadowBias {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Offset")
                                Text(offset, format: .number.precision(.fractionLength(4)))
                                    .monospacedDigit()
                            }
                            HStack {
                                Image(systemName: "plusminus").frame(width: 22).accessibilityHidden(true)
                                Slider(value: $offset, in: -0.02...0.02) { Text("Offset") }
                                    .labelsHidden()
                            }
                            .help("Adds an equal offset to linear RGB before tone mapping. Negative values clip shadows; positive values lift black.")
                        }
                    }
                }
            } else {
                Text("Open a RAW image to adjust decoder settings.").foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .padding()
    }
}
