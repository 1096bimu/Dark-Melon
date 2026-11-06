import CoreImage
import Foundation

nonisolated struct HalationSettings: Codable, Equatable, Sendable {
    var inputCurve = 0.0
    var radius = 0.75
    var transmission = 0.2
}

/// Pre-tone diffusion: red/green in color, equal channel treatment in monochrome.
nonisolated final class Halation {
    private enum HalationError: LocalizedError {
        case kernel
        var errorDescription: String? { String(localized: "Unable to create the Halation processing kernels.") }
    }
    private let shape = MetalImageKernels.color("halationInput")
    private let composite = MetalImageKernels.color("halationAdd")

    /// A zero ceiling preserves scene-linear headroom before tone mapping.
    func apply(to image: CIImage, source: CIImage, settings: HalationSettings,
               hdrBrightness: Double, ceiling: Double, monochrome: Bool = false, sourceScale: Double = 1) throws -> CIImage {
        guard settings.inputCurve > 0 else { return image }
        let input: CIImage
        if settings.inputCurve >= 1 {
            input = source
        } else {
            guard let shaped = shape?.apply(extent: source.extent,
                arguments: [source, 1 / max(settings.inputCurve, 0.000001)]) else { throw HalationError.kernel }
            input = shaped
        }
        let radius = 20 * settings.radius * EffectResolution.scale(shortSide: min(image.extent.width, image.extent.height)) * sourceScale
        let halo = input.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: source.extent)
        // Squaring the Gaussian spatial profile narrows sigma by sqrt(2).
        // Blur normalization preserves channel energy; source HDR values remain linear.
        let greenHalo = !monochrome && settings.transmission > 0
            ? input.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius / sqrt(2.0)])
                .cropped(to: source.extent)
            : halo
        func expanded(_ field: CIImage) -> CIImage {
            guard sourceScale != 1 else { return field }
            return field.clampedToExtent()
                .transformed(by: CGAffineTransform(scaleX: 1 / sourceScale, y: 1 / sourceScale))
                .cropped(to: image.extent)
        }
        guard let output = composite?.apply(extent: image.extent,
            arguments: [image, expanded(halo), expanded(greenHalo), min(1, max(0, hdrBrightness) / 20), settings.transmission.clamped(to: 0...1), ceiling, monochrome ? 1.0 : 0.0]) else { throw HalationError.kernel }
        return output
    }
}
