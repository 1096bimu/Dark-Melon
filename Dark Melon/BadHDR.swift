import CoreImage

nonisolated struct BadHDRSettings: Codable, Equatable, Sendable {
    var strength = 0.0
    var radius = 1.0
}

nonisolated final class BadHDR {
    private lazy var kernel = CIColorKernel(source: """
        kernel vec4 badHDR(__sample original, __sample blurred, float strength, float white, vec3 weights) {
            vec4 p = unpremultiply(original);
            // The SDR-range blurred copy becomes a multiplier from 1 to 0.5.
            // Clamp the mask so HDR highlights cannot invert or darken to black.
            float mask = clamp(dot(unpremultiply(blurred).rgb, weights) / white, 0.0, 1.0);
            // One exposure multiplier preserves RGB ratios. Negative strength
            // applies its reciprocal.
            float multiplier = pow(1.0 - 0.5 * mask, strength);
            return premultiply(vec4(p.rgb * multiplier, p.a));
        }
        """)

    private enum Failure: Error { case kernel }

    func apply(to image: CIImage, settings: BadHDRSettings, whitePoint: Double, weights: SIMD3<Double>) throws -> CIImage {
        guard settings.strength != 0 else { return image }
        let scale = EffectResolution.scale(shortSide: min(image.extent.width, image.extent.height))
        let radius = 50 * min(3, max(0.5, settings.radius)) * scale
        let blurred = image.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: image.extent)
        guard let result = kernel?.apply(extent: image.extent, arguments: [
            image, blurred, min(4, max(-4, settings.strength)), max(ToneMapping.minimumRange, whitePoint),
            CIVector(x: weights.x, y: weights.y, z: weights.z)
        ]) else {
            throw Failure.kernel
        }
        return result
    }
}
