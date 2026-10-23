import SwiftUI

struct PresetApplication: Identifiable {
    let id = UUID()
    let name: String
    let recipe: DevelopmentRecipe
    let selection: SettingsPasteSelection

    func applying(to destination: DevelopmentRecipe, isRAW: Bool) -> DevelopmentRecipe {
        var result = destination
        result.mapping = selection.applying(recipe.mapping, to: destination.mapping)
        if isRAW {
            result.rawSettings = selection.applyingRAW(recipe.rawSettings, to: destination.rawSettings)
            if selection.contains(.rawWhiteBalance), let balance = recipe.mapping.rawWhiteBalance {
                result.mapping.rawWhiteBalance = balance
            }
        }
        return result
    }

    func replacements(isRAW: Bool) -> [PasteItem] {
        PasteItem.allCases.filter {
            guard selection.contains($0) else { return false }
            if $0 == .rawWhiteBalance { return isRAW && recipe.mapping.rawWhiteBalance != nil }
            if $0.rawAdjustment != nil || $0 == .lensCorrection || $0 == .highlightRecovery {
                return isRAW && recipe.rawSettings != nil
            }
            return true
        }
    }
}

/// A temporary render pair for the main preview. Decoder changes are isolated
/// from the active file, so cancellation never alters settings or undo history.
struct PresetPreview {
    let id: UUID
    let recipe: DevelopmentRecipe
    let before: PreviewImages
    let after: PreviewImages
    let development: RAWDevelopment
    let worker: RAWDeveloper

    static func prepare(_ preset: PresetApplication, original: DevelopmentRecipe,
                        development: RAWDevelopment, canvas: CGSize,
                        cachedBefore: PreviewImages?) async throws -> Self {
        let recipe = preset.applying(to: original, isRAW: development.isRAW)
        let worker = RAWDeveloper(colorSpace: recipe.colorSpace, rawSettings: recipe.rawSettings,
                                  rawWhiteBalance: recipe.mapping.rawWhiteBalance)
        let before: PreviewImages
        if let cachedBefore { before = cachedBefore }
        else {
            let renderer = RAWDeveloper(colorSpace: original.colorSpace)
            let source = try await renderer.overview(development, canvas: canvas)
            before = try await renderer.previews(source, mapping: original.mapping)
        }
        try Task.checkCancellation()
        let needsDecode = recipe.rawSettings != original.rawSettings
            || recipe.mapping.rawWhiteBalance != original.mapping.rawWhiteBalance
        let afterDevelopment = needsDecode
            ? try await worker.develop(development.url, previewCanvas: canvas) : development
        let source = try await worker.overview(afterDevelopment, canvas: canvas)
        let after = try await worker.previews(source, mapping: recipe.mapping)
        try Task.checkCancellation()
        return Self(id: preset.id, recipe: recipe, before: before, after: after,
                    development: afterDevelopment, worker: worker)
    }
}

struct PresetConfirmation: View {
    let preset: PresetApplication
    let isRAW: Bool
    @Binding var comparing: Bool
    let ready: Bool
    let error: String?
    let apply: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(preset.name).font(.headline)
            HStack {
                HoldCompareButton(comparing: $comparing, title: "Before / After",
                    help: "Hold to see the current edit. Release to preview the preset.")
                    .disabled(!ready)
                Text(comparing ? "Before" : "After").foregroundStyle(.secondary)
                Spacer()
            }
            if !ready {
                if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
                else { ProgressView("Preparing Preview…").controlSize(.small) }
            }
            Text("Settings to Replace").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(preset.replacements(isRAW: isRAW)) { item in
                        Label(LocalizedStringKey(item.title), systemImage: "arrow.triangle.2.circlepath")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: min(220, max(40, CGFloat(preset.replacements(isRAW: isRAW).count) * 24)))
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Apply Preset") { apply(); dismiss() }
                    .keyboardShortcut(.defaultAction).disabled(!ready)
            }
        }
        .padding()
        .frame(width: 360)
    }
}
