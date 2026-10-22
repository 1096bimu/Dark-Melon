import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Recipe-only browser operations never demosaic or render destination pixels.
struct BrowserRecipeTarget {
    let url: URL
    let recipe: DevelopmentRecipe
    let savedRecipe: DevelopmentRecipe?
    let isRAW: Bool

    static func load(_ url: URL, override: DevelopmentRecipe? = nil) async throws -> Self {
        let saved = try await RecipeStore.shared.load(for: url)
        return try await metadata(url, restored: override ?? saved, saved: saved)
    }

    private nonisolated static func metadata(_ url: URL, restored: DevelopmentRecipe?, saved: DevelopmentRecipe?) async throws -> Self {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let container = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let identifier = CGImageSourceGetType(container) else { throw CocoaError(.fileReadCorruptFile) }
        let raw = UTType(identifier as String)?.conforms(to: .rawImage) == true
        if let restored { return Self(url: url, recipe: restored, savedRecipe: saved, isRAW: raw) }
        let space: ProcessingColorSpace
        let headroom: Double
        if raw {
            space = .displayP3
            headroom = 1
        } else {
            // CIImage is lazy: only inspect its profile/headroom, never render it.
            guard let image = CIImage(contentsOf: url, options: [.expandToHDR: true, .toneMapHDRtoSDR: false]) else { throw CocoaError(.fileReadCorruptFile) }
            space = ProcessingColorSpace.covering(image.colorSpace)
            headroom = Double(image.contentHeadroom)
        }
        return Self(url: url, recipe: DevelopmentRecipe(colorSpace: space,
            mapping: .fresh(isRAW: raw, sourceHeadroom: headroom)), savedRecipe: saved, isRAW: raw)
    }
}
