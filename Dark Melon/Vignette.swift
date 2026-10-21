import CoreImage
import Foundation
import simd

nonisolated struct VignetteSettings: Codable, Equatable, Sendable {
    var amount = 0.0
    var spread = 0.5
}

/// Exposure reduction before tone mapping, positioned in the committed output crop.
nonisolated final class Vignette {
    private enum VignetteError: LocalizedError {
        case kernel
        var errorDescription: String? { String(localized: "Unable to create the Vignette processing kernel.") }
    }

    private let kernel = CIColorKernel(source: """
        kernel vec4 vignetteExposure(__sample pixel, vec4 extent, vec3 row0, vec3 row1,
                                     vec3 row2, float aspect, float amount, float exponent) {
            vec2 source = (destCoord() - extent.xy) / extent.zw;
            vec3 position = vec3(source.x, 1.0 - source.y, 1.0);
            float denominator = dot(row2, position);
            float radius = 1.0;
            // A projective horizon can lie outside the retained crop. Bound its loss
            // to the corner amount so neighboring blur samples stay finite.
            if (abs(denominator) > 0.000001) {
                vec2 crop = vec2(dot(row0, position), dot(row1, position)) / denominator;
                vec2 centered = (2.0 * crop - 1.0) * vec2(aspect, 1.0);
                radius = clamp(length(centered) / sqrt(aspect * aspect + 1.0), 0.0, 1.0);
            }
            float gain = exp2(-amount * pow(radius, exponent));
            return vec4(pixel.rgb * gain, pixel.a);
        }
        """)

    func apply(to image: CIImage, settings: VignetteSettings, transform: TransformSettings?) throws -> CIImage {
        guard settings.amount > 0 else { return image }
        let matrix = transform.map { simd_inverse($0.sourceHomography) } ?? matrix_identity_double3x3
        func row(_ index: Int) -> CIVector {
            CIVector(x: matrix[0][index], y: matrix[1][index], z: matrix[2][index])
        }
        let extent = image.extent
        let aspect = transform?.aspect ?? (extent.width / extent.height)
        guard let result = kernel?.apply(extent: extent, arguments: [
            image, CIVector(x: extent.minX, y: extent.minY, z: extent.width, w: extent.height),
            row(0), row(1), row(2), aspect, settings.amount.clamped(to: 0...4),
            2 * pow(8, 1 - settings.spread.clamped(to: 0...1))
        ]) else { throw VignetteError.kernel }
        return result
    }
}
