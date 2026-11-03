import Foundation
import ImageIO

/// A camera/file preview only, never an editing or sampling source.
actor QuickOpeningPreview {
    private static let worker = QuickOpeningPreview()

    static func image(_ url: URL) async -> CGImage? { await worker.read(url) }

    private func read(_ url: URL) -> CGImage? {
        guard !Task.isCancelled, !DoubleExposure.isDocument(url) else { return nil }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 2560
        ] as CFDictionary)
    }
}
