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
            slopes: SIMD3(slopes[0], slopes[1], slopes[2]), purity: SIMD3(purity[0], purity[1], purity[2]))
    }
}
