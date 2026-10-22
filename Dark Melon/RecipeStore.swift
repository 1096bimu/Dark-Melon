import Foundation
import ImageIO

extension Notification.Name {
    nonisolated static let developmentSettingsChanged = Notification.Name("DarkMelon.developmentSettingsChanged")
}

/// Own sidecar avoids collisions with Lightroom's basename.xmp and with files
/// such as photo.jpg and photo.dng that happen to share the same basename.
actor RecipeStore {
    static let shared = RecipeStore()
    nonisolated private let namespace = "urn:dark-melon:development:1.0/" as CFString
    nonisolated private let path = "darkmelon:Recipe" as CFString
    nonisolated private let maximumSize = 8 * 1024 * 1024

    nonisolated static func sidecarURL(for source: URL) -> URL {
        source.appendingPathExtension("darkmelon.xmp")
    }

    func load(for source: URL) throws -> DevelopmentRecipe? {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        let url = Self.sidecarURL(for: source)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try boundedData(from: url)
        guard let metadata = CGImageMetadataCreateFromXMPData(data as CFData),
              let json = CGImageMetadataCopyStringValueWithPath(metadata, nil, path) else {
            throw StoreError.invalidXMP
        }
        return try DevelopmentRecipe.decode(Data((json as String).utf8))
    }

    nonisolated private static let writeLock = NSLock()

    func save(_ recipe: DevelopmentRecipe, for source: URL) throws {
        try saveSynchronously(recipe, for: source)
    }

    /// Lifecycle flushes must finish before the process/window releases file access.
    @discardableResult
    nonisolated func saveSynchronously(_ recipe: DevelopmentRecipe, for source: URL) throws -> DevelopmentRecipe {
        Self.writeLock.lock()
        defer { Self.writeLock.unlock() }
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        let url = Self.sidecarURL(for: source)
        // Preserve any additional metadata in our sidecar. Refuse to overwrite
        // an unreadable existing document rather than silently discarding it.
        let metadata: CGMutableImageMetadata
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try boundedData(from: url)
            guard let previous = CGImageMetadataCreateFromXMPData(data as CFData),
                  let mutable = CGImageMetadataCreateMutableCopy(previous) else { throw StoreError.invalidXMP }
            metadata = mutable
        } else { metadata = CGImageMetadataCreateMutable() }
        let json = String(decoding: try recipe.encoded(), as: UTF8.self)
        guard CGImageMetadataRegisterNamespaceForPrefix(metadata, namespace, "darkmelon" as CFString, nil),
              CGImageMetadataSetValueWithPath(metadata, nil, path, json as CFString),
              let packet = CGImageMetadataCreateXMPData(metadata, nil) else { throw StoreError.invalidXMP }
        // Atomic replacement writes only the few-kilobyte sidecar, never the image.
        try (packet as Data).write(to: url, options: .atomic)
        NotificationCenter.default.post(name: .developmentSettingsChanged, object: source)
        return recipe
    }

    func delete(for source: URL) throws {
        Self.writeLock.lock()
        defer { Self.writeLock.unlock() }
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        let url = Self.sidecarURL(for: source)
        if FileManager.default.fileExists(atPath: url.path) {
            #if os(macOS)
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                // Network volumes may allow deletion but provide no Trash.
                // Deleting edits was already confirmed; only remove our sidecar.
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                } else {
                    throw error
                }
            }
            #else
            try FileManager.default.removeItem(at: url)
            #endif
        }
        NotificationCenter.default.post(name: .developmentSettingsChanged, object: source)
    }

    nonisolated private func boundedData(from url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumSize + 1) ?? Data()
        guard data.count <= maximumSize else { throw RecipeError.unsupported }
        return data
    }

    private enum StoreError: LocalizedError {
        case invalidXMP
        var errorDescription: String? { String(localized: "The development sidecar is not a valid Dark Melon XMP document.") }
    }
}
