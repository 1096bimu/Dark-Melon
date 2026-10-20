import CoreImage
import Foundation

nonisolated struct HalationSettings: Codable, Equatable, Sendable {
    var inputCurve = 0.0
    var radius = 0.75
    var transmission = 0.2
}

/// Red and adjustable green highlight diffusion, using full pre-tone linear channels.
nonisolated final class Halation {
    private enum HalationError: LocalizedError {
        case kernel
        var errorDescription: String? { String(localized: "Unable to create the Halation processing kernels.") }
    }
    private let shape = CIColorKernel(source: """
        kernel vec4 halationInput(__sample source, float exponent) {
            vec4 p = unpremultiply(source);
            vec3 positive = max(p.rgb, vec3(0.0));
            // Shape the unit interval; preserve above-white headroom without power amplification.
            vec3 shaped = pow(min(positive, vec3(1.0)), vec3(exponent))
                + max(positive - vec3(1.0), vec3(0.0));
            return premultiply(vec4(shaped, p.a));
        }
        """)
    private let composite = CIColorKernel(source: """
        kernel vec4 halationAdd(__sample source, __sample redHalo, __sample greenHalo, float strength, float transmission, float ceiling) {
            vec4 p = unpremultiply(source);
            float red = unpremultiply(redHalo).r;
            float green = unpremultiply(greenHalo).g;
            p.r = clamp(p.r + strength * red, 0.0, ceiling);
            p.g = clamp(p.g + strength * transmission * green, 0.0, ceiling);
            return premultiply(p);
        }
        """)

    func apply(to image: CIImage, source: CIImage, settings: HalationSettings,
               hdrBrightness: Double, ceiling: Double) throws -> CIImage {
        guard settings.inputCurve > 0 else { return image }
        let input: CIImage
        if settings.inputCurve >= 1 {
            input = source
        } else {
            guard let shaped = shape?.apply(extent: source.extent,
                arguments: [source, 1 / max(settings.inputCurve, 0.000001)]) else { throw HalationError.kernel }
            input = shaped
        }
        let radius = 40 * settings.radius * EffectResolution.scale(shortSide: min(image.extent.width, image.extent.height))
        let halo = input.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: image.extent)
        // Squaring the Gaussian spatial profile narrows sigma by sqrt(2).
        // Blur normalization preserves channel energy; source HDR values remain linear.
        let greenHalo = settings.transmission > 0
            ? input.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius / sqrt(2.0)])
                .cropped(to: image.extent)
            : halo
        guard let output = composite?.apply(extent: image.extent,
            arguments: [image, halo, greenHalo, min(1, max(0, hdrBrightness) / 5), min(0.5, max(0, settings.transmission)), ceiling]) else { throw HalationError.kernel }
        return output
    }
}
