import CoreImage

/// A shared, scene-linear quarter-size branch for broad optical effects.
/// Only blur inputs are reduced; every effect composites onto the full image.
nonisolated enum OpticalBlur {
    static let scale = 0.25

    static func source(_ image: CIImage) -> CIImage {
        image.clampedToExtent().applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0
        ]).cropped(to: image.extent.applying(CGAffineTransform(scaleX: scale, y: scale)))
            .insertingIntermediate(cache: true)
    }

    static func gaussian(_ source: CIImage, radius: Double) -> CIImage {
        source.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius * scale])
            .cropped(to: source.extent)
    }

    static func expanded(_ image: CIImage, extent: CGRect) -> CIImage {
        image.clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
            .cropped(to: extent)
    }
}
