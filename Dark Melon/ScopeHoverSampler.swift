import CoreImage

/// Retains CPU-readable preview bytes once per image/color representation.
/// Pointer movement performs only an indexed pixel read; it never submits GPU work.
actor ScopeHoverSampler {
    private enum SamplingError: Error { case unreadableImage }
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var sourceImage: CGImage?
    private var cachedSpace: ProcessingColorSpace?
    private var cachedEncoded = false
    private var pixels: CFData?
    private var rowBytes = 0
    private var halfFloat = false

    /// Decode IEEE binary16 without Swift.Float16, which is unavailable on Intel Macs.
    nonisolated static func decodeHalf(_ bits: UInt16) -> Double {
        let sign = UInt32(bits & 0x8000) << 16
        let exponent = UInt32((bits >> 10) & 0x1f)
        let fraction = UInt32(bits & 0x03ff)
        if exponent == 0 {
            let value = Double(fraction) * 0x1p-24
            return sign == 0 ? value : -value
        }
        let floatExponent: UInt32 = exponent == 31 ? 255 : exponent + 112
        return Double(Float(bitPattern: sign | (floatExponent << 23) | (fraction << 13)))
    }

    private func prepare(_ source: CGImage, space: ProcessingColorSpace, encoded: Bool) throws {
        if sourceImage === source, cachedSpace == space, cachedEncoded == encoded, pixels != nil { return }
        let target = encoded ? space.encoded : space.linear
        func supported(_ image: CGImage) -> Bool {
            let order = image.bitmapInfo.intersection(.byteOrderMask)
            return image.alphaInfo == .premultipliedLast && (
                (image.bitsPerComponent == 8 && image.bitsPerPixel == 32 && order == .byteOrderDefault
                 && !image.bitmapInfo.contains(.floatComponents)) ||
                (image.bitsPerComponent == 16 && image.bitsPerPixel == 64 && order == .byteOrder16Little
                 && image.bitmapInfo.contains(.floatComponents)))
        }
        let bitmap: CGImage
        if source.colorSpace == target, supported(source) {
            bitmap = source
        } else {
            // ColorSync conversion / unusual pixel layouts are resolved once, not per hover.
            let image = CIImage(cgImage: source)
            guard let converted = context.createCGImage(image, from: image.extent,
                format: .RGBAh, colorSpace: target), supported(converted) else { throw SamplingError.unreadableImage }
            bitmap = converted
        }
        guard let data = bitmap.dataProvider?.data,
              CFDataGetLength(data) >= bitmap.bytesPerRow * bitmap.height else { throw SamplingError.unreadableImage }
        try Task.checkCancellation()
        pixels = data
        rowBytes = bitmap.bytesPerRow
        halfFloat = bitmap.bitsPerComponent == 16
        sourceImage = source
        cachedSpace = space
        cachedEncoded = encoded
    }

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
        try prepare(source, space: space, encoded: encoded)
        guard let pixels, let bytes = CFDataGetBytePtr(pixels) else { return nil }
        let x = min(source.width - 1, max(0, Int(position.x * Double(source.width))))
        let y = min(source.height - 1, max(0, Int(position.y * Double(source.height))))
        // CGImage rows start at the top; preview sampling uses Core Image's bottom origin.
        let pixel = bytes.advanced(by: (source.height - 1 - y) * rowBytes + x * (halfFloat ? 8 : 4))
        func component(_ index: Int) -> Double {
            if halfFloat {
                let offset = index * 2
                let bits = UInt16(pixel[offset]) | (UInt16(pixel[offset + 1]) << 8)
                return Self.decodeHalf(bits)
            }
            return Double(pixel[index]) / 255
        }
        let alpha = component(3)
        guard alpha > 0 else { return nil }
        return SIMD3(component(0), component(1), component(2)) / alpha
    }
}
