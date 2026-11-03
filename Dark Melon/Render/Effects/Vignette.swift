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

    private let kernel = MetalImageKernels.color("vignetteExposure")

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
            row(0), row(1), row(2), aspect, settings.amount.clamped(to: AdjustmentLimits.vignetteStops),
            2 * pow(8, 1 - settings.spread.clamped(to: 0...1))
        ]) else { throw VignetteError.kernel }
        return result
    }
}
