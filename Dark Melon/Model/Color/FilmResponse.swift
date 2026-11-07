import CoreImage

/// One shared film stage: input mixing, Digital grain or Analogue dye density,
/// then output mixing. The main SDR/HDR tone curves follow this stage.
nonisolated final class FilmResponse {
    private var grain: FilmGrain?
    private enum Failure: Error { case invalidLayers }

    func apply(to image: CIImage, mapping: ToneMapping, seed: UInt32 = 1,
               luminance: SIMD3<Double> = SIMD3(0.2126, 0.7152, 0.0722), renderScale: Double = 1) throws -> CIImage {
        guard mapping.grain.isEnabled || !mapping.dyeMixers.isIdentity else { return image }
        guard mapping.channelContrast.count == 3, mapping.dyePurity.count == 3 else { throw Failure.invalidLayers }
        if grain == nil { grain = try FilmGrain() }
        let slopes = mapping.dyeContrastOffsets.map { 1 + $0 }
        let purity = mapping.dyePurity
        return try grain!.apply(to: image, settings: mapping.grain, seed: seed,
            luminance: luminance, renderScale: renderScale, mixers: mapping.dyeMixers,
            slopes: SIMD3(slopes[0], slopes[1], slopes[2]), purity: SIMD3(purity[0], purity[1], purity[2]), fog: mapping.analogueFog)
    }
}

extension ToneMapping {
    /// Keep the noise-free fog's SDR black lift at or below its ungraded level.
    /// Derived from the cached tone curve, independent of grain strength and HDR
    /// gain, so both renditions and LUT export use the same film density.
    var analogueFog: Double {
        let maximum = FilmGrain.defaultFog
        guard grain.output == .filmDensity else { return maximum }
        let black = -expm1(-maximum)
        // Equal black densities pass through purity unchanged. Account for
        // output-matrix amplification before the main tone curve as well.
        let b = dyeMixers.b
        guard b.count == 9 else { return maximum }
        let gain = max(0, max(b[0]+b[1]+b[2], max(b[3]+b[4]+b[5], b[6]+b[7]+b[8])))
        guard gain > 0 else { return maximum }
        let curve = curve(hdr: false)
        guard curve.value(at: black * gain) > black else { return maximum }
        var low = 0.0, high = black * gain
        // Invert the actual piecewise-linear curve, including distribution and
        // white-point adjustments. This is scalar work, never image analysis.
        for _ in 0..<40 {
            let middle = (low + high) / 2
            if curve.value(at: middle) > black { high = middle }
            else { low = middle }
        }
        return min(maximum, -log1p(-low / gain))
    }
}
