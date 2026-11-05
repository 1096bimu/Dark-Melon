import CoreImage

/// Source geometry is stored with decoder settings but applied after decoding.
nonisolated struct SourceOrientation: Codable, Equatable, Sendable {
    var quarterTurns = 0
    var mirrored = false
    var turns: Int { ((quarterTurns % 4) + 4) % 4 }
    var halfTurnsOnly: Self { Self(quarterTurns: turns & 2, mirrored: mirrored) }

    /// Normalized coordinates with the same top-left origin as saved crop points.
    func apply(to point: CGPoint) -> CGPoint {
        var result = point
        for _ in 0..<turns { result = CGPoint(x: 1 - result.y, y: result.x) }
        if mirrored { result.x = 1 - result.x }
        return result
    }

    func sourcePoint(_ point: CGPoint) -> CGPoint {
        var result = point
        if mirrored { result.x = 1 - result.x }
        for _ in 0..<turns { result = CGPoint(x: result.y, y: 1 - result.x) }
        return result
    }
    func apply(to image: CIImage, includeMirror: Bool = true) -> CIImage {
        let exif: [Int32] = [1, 6, 3, 8]
        var result = image.oriented(forExifOrientation: exif[turns])
        if includeMirror && mirrored { result = result.oriented(forExifOrientation: 2) }
        return result.transformed(by: CGAffineTransform(translationX: -result.extent.minX, y: -result.extent.minY))
    }
}
