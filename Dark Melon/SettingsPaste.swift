import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

nonisolated struct SettingsPasteSelection {
    var tone = true
    var whiteBalance = true
    var color = true
    var effects = true
    var raw = true
    var isEmpty: Bool { !tone && !whiteBalance && !color && !effects && !raw }

    func applying(_ source: ToneMapping, to destination: ToneMapping) -> ToneMapping {
        var result = destination
        if raw { result.offset = source.offset }
        if tone {
            result.black = source.black
            result.white = source.white
            result.tonePosition = source.tonePosition
            result.concentration = source.concentration
            result.hdrTarget = source.hdrTarget
            result.hdrGain = source.hdrGain
            result.hdrRolloff = source.hdrRolloff
        }
        if whiteBalance {
            result.whiteBalance = source.whiteBalance
            if let rawBalance = source.rawWhiteBalance, destination.rawWhiteBalance != nil {
                result.rawWhiteBalance = rawBalance
            }
        }
        if color { result.color = source.color; result.vertexWarp = source.vertexWarp; result.hls = source.hls; result.blackAndWhite = source.blackAndWhite }
        if effects {
            result.clarity = source.clarity
            result.clarityRadius = source.clarityRadius
            result.hdf = source.hdf
            result.hdfRadius = source.hdfRadius
            result.grain = source.grain
            result.halation = source.halation
            result.vignette = source.vignette
        }
        return result
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
    @Environment(\.dismiss) private var dismiss
    @AppStorage("pasteSettings.tone") private var tone = true
    @AppStorage("pasteSettings.whiteBalance") private var whiteBalance = true
    @AppStorage("pasteSettings.color") private var color = true
    @AppStorage("pasteSettings.effects") private var effects = true
    @AppStorage("pasteSettings.raw") private var raw = true
    private var selection: SettingsPasteSelection {
        SettingsPasteSelection(tone: tone, whiteBalance: whiteBalance, color: color, effects: effects, raw: raw)
    }

    var body: some View {
        NavigationStack {
            Form {
                Toggle("Tone", isOn: $tone)
                Toggle("White Balance", isOn: $whiteBalance)
                Toggle("Color", isOn: $color)
                Toggle("Effects", isOn: $effects)
                Toggle("RAW", isOn: $raw)
            }
            .formStyle(.grouped)
            .navigationTitle("Paste Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Paste") { apply(selection); dismiss() }
                        .disabled(selection.isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(width: 340, height: 360)
        #endif
    }
}
