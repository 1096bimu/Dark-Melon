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
        kernel vec4 halationAdd(__sample source, __sample redHalo, __sample greenHalo, float strength, float transmission, float ceiling, float monochrome) {
            vec4 p = unpremultiply(source);
            if (monochrome > 0.5) {
                p.rgb = max(p.rgb + strength * unpremultiply(redHalo).rgb, vec3(0.0));
                if (ceiling > 0.0) { p.rgb = min(p.rgb, vec3(ceiling)); }
                return premultiply(p);
            }
            float red = unpremultiply(redHalo).r;
            float green = unpremultiply(greenHalo).g;
            p.r = max(p.r + strength * red, 0.0);
            p.g = max(p.g + strength * transmission * green, 0.0);
            if (ceiling > 0.0) { p.rg = min(p.rg, vec2(ceiling)); }
            return premultiply(p);
        }
        """)

    /// A zero ceiling preserves scene-linear headroom before tone mapping.
    func apply(to image: CIImage, source: CIImage, settings: HalationSettings,
               hdrBrightness: Double, ceiling: Double, monochrome: Bool = false) throws -> CIImage {
        guard settings.inputCurve > 0 else { return image }
        let input: CIImage
        if settings.inputCurve >= 1 {
            input = source
        } else {
            guard let shaped = shape?.apply(extent: source.extent,
                arguments: [source, 1 / max(settings.inputCurve, 0.000001)]) else { throw HalationError.kernel }
            input = shaped
        }
        let radius = 20 * settings.radius * EffectResolution.scale(shortSide: min(image.extent.width, image.extent.height))
        let halo = input.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: image.extent)
        // Squaring the Gaussian spatial profile narrows sigma by sqrt(2).
        // Blur normalization preserves channel energy; source HDR values remain linear.
        let greenHalo = !monochrome && settings.transmission > 0
            ? input.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius / sqrt(2.0)])
                .cropped(to: image.extent)
            : halo
        guard let output = composite?.apply(extent: image.extent,
            arguments: [image, halo, greenHalo, min(1, max(0, hdrBrightness) / 20), min(0.5, max(0, settings.transmission)), ceiling, monochrome ? 1.0 : 0.0]) else { throw HalationError.kernel }
        return output
    }
}
