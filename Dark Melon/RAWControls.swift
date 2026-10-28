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

nonisolated enum RAW9Mode: String, Codable, CaseIterable, Sendable {
    case on, off, exportOnly

    var title: String {
        switch self {
        case .on: "On"
        case .off: "Off"
        case .exportOnly: "Export Only"
        }
    }

    func enabled(exporting: Bool) -> Bool { self == .on || (self == .exportOnly && exporting) }
}

nonisolated struct RAWSettings: Codable, Equatable, Sendable {
    static let maximizeRangePreferenceKey = "alwaysMaximizeRAWRange"
    var useRAW9: Bool? = nil // Missing in older recipes means the legacy/default decoder.
    var raw9Mode: RAW9Mode? = nil
    var decoderMode: RAW9Mode {
        get { raw9Mode ?? (useRAW9 == true ? .on : .off) }
        set { raw9Mode = newValue; useRAW9 = nil }
    }
    var supportsRAW9 = false
    var values: [RAWAdjustment: Float] = [:]
    var supported: Set<RAWAdjustment> = []
    var lensCorrection = false
    var supportsLensCorrection = false
    /// Nil means a complete legacy recipe; a set describes sparse browser pastes.
    var selectedSwitches: Set<String>? = nil
    var highlightRecovery = true
    var supportsHighlightRecovery = false

    private enum CodingKeys: String, CodingKey { case values, lensCorrection, highlightRecovery, selectedSwitches, useRAW9, raw9Mode }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.decoderMode == rhs.decoderMode && lhs.values == rhs.values && lhs.lensCorrection == rhs.lensCorrection && lhs.highlightRecovery == rhs.highlightRecovery && lhs.selectedSwitches == rhs.selectedSwitches
    }

    /// Capabilities always belong to the destination decoder, not the saved recipe.
    func resolved(using defaults: Self) -> Self {
        var result = defaults
        if selectedSwitches == nil || selectedSwitches!.contains("decoder") { result.decoderMode = decoderMode }
        result.values.merge(values) { _, saved in saved }
        if selectedSwitches == nil || selectedSwitches!.contains("lens") { result.lensCorrection = lensCorrection }
        if selectedSwitches == nil || selectedSwitches!.contains("highlight") { result.highlightRecovery = highlightRecovery }
        return result
    }

    /// Use the advertised identifiers so the macOS 26 build does not link to
    /// RAW 9 constants that only exist in the macOS 27 Core Image framework.
    static func raw9Version(_ raw: CIRAWFilter) -> CIRAWDecoderVersion? {
        raw.supportedDecoderVersions.first { $0.rawValue == "9" || $0.rawValue == "9.dng" }
    }
    init() {}
    init(_ raw: CIRAWFilter) {
        supportsRAW9 = Self.raw9Version(raw) != nil

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
        if raw.isLensCorrectionSupported && (selectedSwitches == nil || selectedSwitches!.contains("lens")) { raw.isLensCorrectionEnabled = lensCorrection }
        if raw.isHighlightRecoverySupported && (selectedSwitches == nil || selectedSwitches!.contains("highlight")) { raw.isHighlightRecoveryEnabled = highlightRecovery }
    }
}

struct RAWControls: View {
    @Environment(\.resetRAWSettings) private var rawDefaults
    @Environment(\.resetMapping) private var defaults
    @AppStorage("showAdvancedRAWControls") private var showAdvancedRAWControls = false
    @Environment(\.lockedFilmItems) private var lockedItems
    @Binding var settings: RAWSettings
    @Binding var offset: Double
    let isRAW: Bool
    let commit: () -> Void
    let reset: () -> Void
    var maximizingRange = false
    var maxRange: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("RAW").font(.headline)
                Spacer()
                if maximizingRange { ProgressView().controlSize(.small) }
                Button("Max Range", action: maxRange).disabled(!isRAW || maximizingRange || lockedItems.contains(.exposure) || lockedItems.contains(.shadowBias))
                Button("Reset RAW", action: reset).disabled(!isRAW || maximizingRange)
            }
            if isRAW {
                Picker("RAW 9", selection: Binding(get: { settings.decoderMode }, set: {
                    settings.decoderMode = $0; commit()
                })) {
                    ForEach(RAW9Mode.allCases, id: \.self) { mode in
                        Text(LocalizedStringKey(mode.title)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!settings.supportsRAW9).filmLock(.rawDecoder)
                .help("Uses Apple's neural demosaic and denoise when supported. Changing the decoder may change detail and color.")
                Toggle("Lens Correction", isOn: Binding(get: { settings.lensCorrection }, set: {
                    settings.lensCorrection = $0; commit()
                }))
                .disabled(!settings.supportsLensCorrection).filmLock(.lensCorrection)
                Toggle("Highlight Recovery", isOn: Binding(get: { settings.highlightRecovery }, set: {
                    settings.highlightRecovery = $0; commit()
                }))
                .disabled(!settings.supportsHighlightRecovery).filmLock(.highlightRecovery)
                ForEach(RAWAdjustment.allCases.filter { showAdvancedRAWControls || $0 == .exposure || $0 == .shadowBias }) { control in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(LocalizedStringKey(control.rawValue))
                            if control == .shadowBias { ControlInfo(.shadowBias) }
                            Spacer()
                            Text(settings.values[control] ?? 0, format: .number.precision(.fractionLength(2)))
                                .foregroundStyle(.secondary).monospacedDigit()
                            if control == .exposure { Text("EV").foregroundStyle(.secondary) }
                        }
                        EditorSlider(value: Binding(get: { settings.values[control] ?? 0 }, set: {
                            settings.values[control] = $0
                        }), in: control.minimum...control.maximum, onEditingChanged: { editing in
                            if !editing { commit() }
                        })
                        .controlReset { settings.values[control] = rawDefaults?.values[control] ?? 0 }
                        .accessibilityLabel(LocalizedStringKey(control.rawValue))
                    }
                    .disabled(!settings.supported.contains(control) || lockedItems.contains(where: { $0.rawAdjustment == control }))
                    if control == .shadowBias && showAdvancedRAWControls {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Offset")
                                Text(offset, format: .number.precision(.fractionLength(4)))
                                    .monospacedDigit()
                            }
                            HStack {
                                Image(systemName: "plusminus").frame(width: 22).accessibilityHidden(true)
                                EditorSlider(value: $offset, in: -0.02...0.02, label: { Text("Offset") })
                                    .controlReset { offset = defaults.offset }
                                    .labelsHidden()
                            }
                            .filmLock(.offset)
                            .help("Adds an equal offset to linear RGB before tone mapping. Negative values clip shadows; positive values lift black.")
                        }
                    }
                }
            } else {
                Text("Open a RAW image to adjust decoder settings.").foregroundStyle(.secondary)
            }
        }
        .disabled(maximizingRange)
        .toggleStyle(.switch)
        .padding()
    }
}
