import CoreImage

/// Film-inspired color response relative to a neutral film, not a fitted stock.
/// Optical effects feed this stage; both SDR and HDR tone maps consume its output.
nonisolated final class FilmResponse {
    // A positive-film density sigmoid has D = Dmin + range * (1 - sigmoid).
    // Dividing its transmission by the neutral film's transmission cancels the
    // common compression: E' = E * 2^(8 * (sigmoid_channel - sigmoid_neutral)).
    // h = log2(E / Tone); width = 2 stops; slope = 1 + channel offset.
    // Thus E=Tone is fixed, equal sliders are identity, and no HDR ceiling enters.
    // d(log2 E')/dh = 1 + 4*(s*p*(1-p) - q*(1-q)) > 0 for s > 0.
    // This preserves monotonic layer responses without extra global tone mapping.
    private enum Failure: LocalizedError {
        case processing
        var errorDescription: String? { String(localized: "Film response processing failed.") }
    }
    private lazy var kernel = MetalImageKernels.color("filmResponse")

    func apply(to image: CIImage, mapping: ToneMapping) throws -> CIImage {
        let offsets = mapping.dyeContrastOffsets
        let mixers = mapping.dyeMixers
        guard mapping.dyePurity != [1, 1, 1] || !mixers.isIdentity || offsets.contains(where: { abs($0) > 1e-12 }) else { return image }
        guard mixers.isValid, mapping.dyePurity.count == 3, mapping.dyePurity.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw Failure.processing }
        let rows = [mixers.a, mixers.b].flatMap { matrix in
            stride(from: 0, to: 9, by: 3).map { i in
                CIVector(x: matrix[i], y: matrix[i + 1], z: matrix[i + 2])
            }
        }
        let slopes = CIVector(x: 1 + offsets[0], y: 1 + offsets[1], z: 1 + offsets[2])
        // Tone can be exactly zero. Only the logarithm's reference needs a floor.
        guard let result = kernel?.apply(extent: image.extent,
            arguments: [image] + rows + [slopes, max(1e-6, mapping.tonePosition),
                CIVector(x: mapping.dyePurity[0], y: mapping.dyePurity[1], z: mapping.dyePurity[2])]) else {
            throw Failure.processing
        }
        return result
    }
}
