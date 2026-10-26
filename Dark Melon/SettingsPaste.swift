import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

nonisolated enum PasteItem: String, CaseIterable, Codable, Sendable, Identifiable {
    // Preserve saved selections from the experimental Skew control.
    case contrastDistribution = "skew"
    case tone, contrast, whitePoint, hdrGain, hdrRolloff, rgbWhiteBalance, rawWhiteBalance
    case chromaCurve, lightnessChromaCurve, vertices, hueTwister, splitTone
    case dyeResponse, clarity, hdf, grain, halation, vignette, badHDR
    case transform, lut
    case rawDecoder, exposure, shadowBias, offset, luminanceNoise, colorNoise, sharpness, detail, edgeContrast, moire, lensCorrection, highlightRecovery
    var id: Self { self }
    var title: String {
        switch self {
        case .tone: "Tone"
        case .contrast: "Contrast"
        case .contrastDistribution: "Contrast Distribution"
        case .whitePoint: "White Point"
        case .hdrGain: "HDR Gain"
        case .hdrRolloff: "HDR Rolloff"
        case .rgbWhiteBalance: "RGB White Balance"
        case .rawWhiteBalance: "RAW Kelvin White Balance"
        case .chromaCurve: "Chroma → Chroma"
        case .lightnessChromaCurve: "Lightness → Chroma"
        case .vertices: "Color Nodes"
        case .hueTwister: "HUE Twister"
        case .splitTone: "Split Tone"
        case .dyeResponse: "Dye Response"
        case .clarity: "Clarity"
        case .hdf: "HDF"
        case .grain: "Film Grain"
        case .halation: "Halation"
        case .vignette: "Vignette"
        case .badHDR: "BadHDR"
        case .transform: "Transform"
        case .lut: "LUT"
        case .rawDecoder: "RAW 9"
        case .exposure: "Exposure"
        case .shadowBias: "Shadow Bias"
        case .offset: "Offset"
        case .luminanceNoise: "Luminance Noise Reduction"
        case .colorNoise: "Color Noise Reduction"
        case .sharpness: "Sharpness"
        case .detail: "Detail"
        case .edgeContrast: "Local Edge Contrast"
        case .moire: "Moiré Reduction"
        case .lensCorrection: "Lens Correction"
        case .highlightRecovery: "Highlight Recovery"
        }
    }
    var rawAdjustment: RAWAdjustment? {
        switch self {
        case .exposure: .exposure
        case .shadowBias: .shadowBias
        case .luminanceNoise: .luminance
        case .colorNoise: .color
        case .sharpness: .sharpness
        case .detail: .detail
        case .edgeContrast: .contrast
        case .moire: .moire
        default: nil
        }
    }
    static let toneItems: [Self] = [.tone,.contrast,.contrastDistribution,.whitePoint,.hdrGain,.hdrRolloff]
    static let balanceItems: [Self] = [.rgbWhiteBalance,.rawWhiteBalance]
    static let colorItems: [Self] = [.chromaCurve,.lightnessChromaCurve,.vertices,.hueTwister,.splitTone]
    static let effectItems: [Self] = [.dyeResponse,.clarity,.hdf,.grain,.halation,.vignette,.badHDR]
    static let rawItems: [Self] = [.rawDecoder,.exposure,.shadowBias,.offset,.luminanceNoise,.colorNoise,.sharpness,.detail,.edgeContrast,.moire,.lensCorrection,.highlightRecovery]
}

/// Legacy group flags keep existing Library entries and internal reset callers compatible.
/// New selections store independent leaves.
nonisolated struct SettingsPasteSelection: Codable, Sendable, Equatable {
    var tone = true
    var whiteBalance = true
    var color = true
    var effects = true
    var raw = true
    var items: Set<PasteItem>? = nil

    private enum CodingKeys: String, CodingKey { case tone, whiteBalance, color, effects, raw, items }

    func contains(_ item: PasteItem) -> Bool {
        if let items { return items.contains(item) }
        if PasteItem.toneItems.contains(item) { return tone }
        if PasteItem.balanceItems.contains(item) { return whiteBalance }
        if PasteItem.colorItems.contains(item) { return color }
        if PasteItem.effectItems.contains(item) { return effects }
        if PasteItem.rawItems.contains(item) { return raw }
        return false // Transform was not included in legacy selections.
    }
    var selectedItems: Set<PasteItem> { Set(PasteItem.allCases.filter(contains)) }
    var isEmpty: Bool { selectedItems.isEmpty }
    mutating func set(_ item: PasteItem, enabled: Bool) {
        var selected = selectedItems
        if enabled { selected.insert(item) } else { selected.remove(item) }
        items = selected
    }

    func applying(_ source: ToneMapping, to destination: ToneMapping) -> ToneMapping {
        var result = destination
        if contains(.offset) { result.offset = source.offset }
        if contains(.whitePoint) { result.white = source.white }
        if contains(.tone) { result.tonePosition = source.tonePosition }
        if contains(.contrast) { result.concentration = source.concentration }
        if contains(.contrastDistribution) { result.contrastDistribution = source.contrastDistribution }
        result.tonePosition = min(result.white, result.tonePosition)
        if contains(.tone) || contains(.contrast) || contains(.whitePoint) || contains(.contrastDistribution) { result.setAutomaticHDRTarget() }
        if contains(.hdrGain) { result.hdrGain = source.hdrGain }
        if contains(.hdrRolloff) { result.hdrRolloff = source.hdrRolloff }
        if contains(.rgbWhiteBalance) { result.whiteBalance = source.whiteBalance }
        if contains(.rawWhiteBalance), destination.rawWhiteBalance != nil, let balance = source.rawWhiteBalance {
            result.rawWhiteBalance = balance
        }
        if contains(.chromaCurve) {
            result.color.saturationStart = source.color.saturationStart
            result.color.saturationMid = source.color.saturationMid
            result.color.saturationEnd = source.color.saturationEnd
            result.color.saturationHDR = source.color.saturationHDR
        }
        if contains(.lightnessChromaCurve) {
            result.color.luminanceSaturationStart = source.color.luminanceSaturationStart
            result.color.luminanceSaturationMid = source.color.luminanceSaturationMid
            result.color.luminanceSaturationEnd = source.color.luminanceSaturationEnd
            result.color.luminanceSaturationHDR = source.color.luminanceSaturationHDR
        }
        for i in result.vertexWarp.indices {
            if contains(.vertices) {
                result.vertexWarp[i].chroma = source.vertexWarp[i].chroma
                result.vertexWarp[i].lightness = source.vertexWarp[i].lightness
                result.vertexWarp[i].rotation = source.vertexWarp[i].rotation
                result.vertexWarp[i].hueOffset = source.vertexWarp[i].hueOffset
            }
            if contains(.hueTwister) {
                result.vertexWarp[i].darkerHue = source.vertexWarp[i].darkerHue
                result.vertexWarp[i].lighterHue = source.vertexWarp[i].lighterHue
            }
        }
        if contains(.vertices) { result.color.monochrome = source.color.monochrome; result.hls = source.hls; result.blackAndWhite = source.blackAndWhite }
        if contains(.splitTone) { result.color.splitTone = source.color.splitTone }
        if contains(.dyeResponse) { result.channelContrast = source.channelContrast }
        if contains(.clarity) { result.clarity = source.clarity; result.clarityRadius = source.clarityRadius }
        if contains(.hdf) { result.hdf = source.hdf; result.hdfRadius = source.hdfRadius }
        if contains(.grain) { result.grain = source.grain }
        if contains(.halation) { result.halation = source.halation }
        if contains(.vignette) { result.vignette = source.vignette }
        if contains(.badHDR) { result.badHDR = source.badHDR }
        if contains(.transform) { result.transform = source.transform }
        if contains(.lut) { result.lutID = source.lutID }
        return result
    }

    func applyingRAW(_ source: RAWSettings?, to destination: RAWSettings?) -> RAWSettings? {
        guard let source else { return destination }
        let decoderItems = PasteItem.rawItems.filter { $0 != .offset && contains($0) }
        guard !decoderItems.isEmpty else { return destination }
        var result = destination ?? RAWSettings()
        if destination == nil { result.selectedSwitches = [] }
        for item in PasteItem.rawItems where contains(item) {
            if let control = item.rawAdjustment, let value = source.values[control] { result.values[control] = value }
        }
        if contains(.rawDecoder), source.selectedSwitches == nil || source.selectedSwitches!.contains("decoder") {
            result.decoderMode = source.decoderMode
            result.selectedSwitches?.insert("decoder")
        }
        if contains(.lensCorrection), source.selectedSwitches == nil || source.selectedSwitches!.contains("lens") {
            result.lensCorrection = source.lensCorrection
            result.selectedSwitches?.insert("lens")
        }
        if contains(.highlightRecovery), source.selectedSwitches == nil || source.selectedSwitches!.contains("highlight") {
            result.highlightRecovery = source.highlightRecovery
            result.selectedSwitches?.insert("highlight")
        }
        return result
    }
}

// Ignore removed/unknown selection leaves without losing an entire preset or
// saved preference. Declared separately to preserve the memberwise initializer.
extension SettingsPasteSelection {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        tone = try values.decodeIfPresent(Bool.self, forKey: .tone) ?? true
        whiteBalance = try values.decodeIfPresent(Bool.self, forKey: .whiteBalance) ?? true
        color = try values.decodeIfPresent(Bool.self, forKey: .color) ?? true
        effects = try values.decodeIfPresent(Bool.self, forKey: .effects) ?? true
        raw = try values.decodeIfPresent(Bool.self, forKey: .raw) ?? true
        items = try values.decodeIfPresent([String].self, forKey: .items).map {
            Set($0.compactMap(PasteItem.init(rawValue:)))
        }
    }
}

/// Clipboard recipes preserve RGB gains and optional RAW decoder white balance.
nonisolated struct CopiedSettings {
    let mapping: ToneMapping
    var rawSettings: RAWSettings? = nil

    func applying(_ selection: SettingsPasteSelection, to destination: ToneMapping,
                  reference: RAWWhitePoint?, space: ProcessingColorSpace) -> ToneMapping {
        selection.applying(mapping, to: destination)
    }

    static func encode(_ recipe: DevelopmentRecipe, reference: RAWWhitePoint?) throws -> Data {
        try recipe.encoded()
    }

    static func decode(_ data: Data) throws -> Self {
        let recipe = try DevelopmentRecipe.decode(data)
        return Self(mapping: recipe.mapping, rawSettings: recipe.rawSettings)
    }
}

@MainActor enum SettingsClipboard {
    private static let type = "com.darkmelon.development-settings"
    static func copy(_ recipe: DevelopmentRecipe, reference: RAWWhitePoint?, source: URL) throws {
        let data = try CopiedSettings.encode(recipe, reference: reference)
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: NSPasteboard.PasteboardType(type))
        #else
        UIPasteboard.general.setData(data, forPasteboardType: type)
        #endif
    }
    static func read() throws -> CopiedSettings {
        #if os(macOS)
        let data = NSPasteboard.general.data(forType: NSPasteboard.PasteboardType(type))
        #else
        let data = UIPasteboard.general.data(forPasteboardType: type)
        #endif
        guard let data else { throw ClipboardError.empty }
        return try CopiedSettings.decode(data)
    }
    private enum ClipboardError: LocalizedError {
        case empty
        var errorDescription: String? { String(localized: "Copy development settings from an image first.") }
    }
}

struct SettingsPasteOptions: View {
    let apply: (SettingsPasteSelection) -> Void
    var title: LocalizedStringKey = "Paste Settings"
    var actionTitle: LocalizedStringKey = "Paste"
    var selectingLock = false
    @Environment(\.dismiss) private var dismiss
    @State private var selection: SettingsPasteSelection = {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: "pasteSettings.selection"),
           let saved = try? JSONDecoder().decode(SettingsPasteSelection.self, from: data) { return saved }
        func old(_ key: String) -> Bool { defaults.object(forKey: key) as? Bool ?? true }
        return SettingsPasteSelection(tone: old("pasteSettings.tone"),
            whiteBalance: old("pasteSettings.whiteBalance"), color: old("pasteSettings.color"),
            effects: old("pasteSettings.effects"), raw: old("pasteSettings.raw"))
    }()
    private var selectionPreferenceKey: String {
        selectingLock ? "filmLock.selection" : "pasteSettings.selection"
    }
    @State private var expanded: Set<String> = []
    private struct Choice {
        let item: PasteItem
        var enabled: Bool
    }
    private func choices(_ items: [PasteItem]) -> Binding<[Choice]> {
        Binding(get: { items.map { Choice(item: $0, enabled: selection.contains($0)) } },
                set: { values in for value in values { selection.set(value.item, enabled: value.enabled) } })
    }
    private func tree(_ title: String, items: [PasteItem]) -> some View {
        DisclosureGroup(isExpanded: Binding(get: { expanded.contains(title) }, set: {
            if $0 { expanded.insert(title) } else { expanded.remove(title) }
        })) {
            ForEach(items) { item in
                Toggle(LocalizedStringKey(item.title), isOn: Binding(
                    get: { selection.contains(item) }, set: { selection.set(item, enabled: $0) }))
                    .padding(.leading, 8)
            }
        } label: {
            Toggle(LocalizedStringKey(title), sources: choices(items), isOn: \.enabled)
                .fontWeight(.medium)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                HStack {
                    if selectingLock {
                        Button("Film") { selection = FilmSettings.film }
                        Button("Digital") { selection = FilmSettings.digital }
                    }
                    Button("All") { selection = SettingsPasteSelection(items: Set(PasteItem.allCases)) }
                    Button("None") { selection = SettingsPasteSelection(items: []) }
                }.buttonStyle(.bordered).tint(.secondary).focusEffectDisabled()
                tree("Tone", items: PasteItem.toneItems + PasteItem.balanceItems)
                tree("Color", items: PasteItem.colorItems)
                tree("Effects", items: PasteItem.effectItems)
                tree("Transform", items: [.transform])
                tree("RAW", items: PasteItem.rawItems)
                tree("LUT", items: [.lut])
                if selectingLock {
                    Text("These settings will apply to every photo you open and every export, including batch exports, overriding saved settings where they differ. Any resulting changes remain unsaved until you save them. Consider whether you want to save edits made from this point forward.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            #if os(macOS)
            .toggleStyle(.checkbox)
            #endif
            .onAppear {
                if selectingLock {
                    if let data = UserDefaults.standard.data(forKey: selectionPreferenceKey),
                       let saved = try? JSONDecoder().decode(SettingsPasteSelection.self, from: data) {
                        selection = FilmSettings.restoredSelection(saved)
                    } else {
                        selection = FilmSettings.film
                    }
                }
            }
            .onChange(of: selection) { _, value in
                if let data = try? JSONEncoder().encode(value) {
                    UserDefaults.standard.set(data, forKey: selectionPreferenceKey)
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(actionTitle) { apply(selection); dismiss() }
                        .disabled(selection.isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(width: 420, height: 620)
        #endif
    }
}
