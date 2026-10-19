import CoreImage

/// Reads one pixel from the cached preview; no image development or full-frame readback.
actor ScopeHoverSampler {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var revision: UUID?
    private var image: CIImage?

    func sample(_ source: CGImage, revision: UUID, position: CGPoint,
                space: ProcessingColorSpace) throws -> CGPoint? {
        guard let rgb = try sampleRGB(source, revision: revision, position: position, space: space) else { return nil }
        let bounded = SIMD3(min(1,max(0,rgb.x)), min(1,max(0,rgb.y)), min(1,max(0,rgb.z)))
        let lab = ScopeProjection.lab(bounded, space: space)
        return CGPoint(x: lab.y / ScopeProjection.radius, y: -lab.z / ScopeProjection.radius)
    }

    func sampleRGB(_ source: CGImage, revision: UUID, position: CGPoint,
                   space: ProcessingColorSpace, encoded: Bool = false) throws -> SIMD3<Double>? {
        try Task.checkCancellation()
        if self.revision != revision {
            image = CIImage(cgImage: source)
            self.revision = revision
        }
        guard let image else { throw CancellationError() }
        let x = min(source.width - 1, max(0, Int(position.x * Double(source.width))))
        let y = min(source.height - 1, max(0, Int(position.y * Double(source.height))))
        var pixel = [Float](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes {
            context.render(image, toBitmap: $0.baseAddress!, rowBytes: 16,
                           bounds: CGRect(x: x, y: y, width: 1, height: 1),
                           format: .RGBAf, colorSpace: encoded ? space.encoded : space.linear)
        }
        try Task.checkCancellation()
        let alpha = Double(pixel[3])
        guard alpha > 0 else { return nil }
        return SIMD3(Double(pixel[0]), Double(pixel[1]), Double(pixel[2])) / alpha
    }
}
