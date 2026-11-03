import CoreImage

/// Source geometry is stored with decoder settings but applied after decoding.
nonisolated struct SourceOrientation: Codable, Equatable, Sendable {
    var quarterTurns = 0
    var mirrored = false
    var turns: Int { ((quarterTurns % 4) + 4) % 4 }
    var halfTurnsOnly: Self { Self(quarterTurns: turns & 2, mirrored: mirrored) }
    func apply(to image: CIImage, includeMirror: Bool = true) -> CIImage {
        let exif: [Int32] = [1, 6, 3, 8]
        var result = image.oriented(forExifOrientation: exif[turns])
        if includeMirror && mirrored { result = result.oriented(forExifOrientation: 2) }
        return result.transformed(by: CGAffineTransform(translationX: -result.extent.minX, y: -result.extent.minY))
    }
}
