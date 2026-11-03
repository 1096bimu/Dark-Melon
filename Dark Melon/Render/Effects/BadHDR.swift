import CoreImage

nonisolated struct BadHDRSettings: Codable, Equatable, Sendable {
    var strength = 0.0
    var radius = 1.0
}

nonisolated final class BadHDR {
    private lazy var kernel = MetalImageKernels.color("badHDR")

    private enum Failure: Error { case kernel }

    func apply(to image: CIImage, settings: BadHDRSettings, whitePoint: Double, weights: SIMD3<Double>) throws -> CIImage {
        guard settings.strength != 0 else { return image }
        let scale = EffectResolution.scale(shortSide: min(image.extent.width, image.extent.height))
        let radius = 50 * settings.radius.clamped(to: AdjustmentLimits.radius) * scale
        let blurred = image.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: image.extent)
        guard let result = kernel?.apply(extent: image.extent, arguments: [
            image, blurred, settings.strength.clamped(to: AdjustmentLimits.signedStrength), max(ToneMapping.minimumRange, whitePoint),
            CIVector(x: weights.x, y: weights.y, z: weights.z)
        ]) else {
            throw Failure.kernel
        }
        return result
    }
}
