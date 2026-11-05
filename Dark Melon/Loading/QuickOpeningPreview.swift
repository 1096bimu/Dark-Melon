import Foundation
import ImageIO

/// A camera/file preview only, never an editing or sampling source.
actor QuickOpeningPreview {
    private static let worker = QuickOpeningPreview()

    static func image(_ url: URL, canvas: CGSize) async -> CGImage? { await worker.read(url, canvas: canvas) }

    private func read(_ url: URL, canvas: CGSize) -> CGImage? {
        guard !Task.isCancelled, !DoubleExposure.isDocument(url) else { return nil }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, max(canvas.width, canvas.height))
        ] as CFDictionary)
    }
}
