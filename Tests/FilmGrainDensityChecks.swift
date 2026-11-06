import Foundation
import CoreImage
@testable import Dark_Melon

@main struct FilmGrainDensityChecks {
    static func main() async throws {
        let space = ProcessingColorSpace.sRGB
        let context = CIContext(options: [.workingColorSpace: space.linear, .workingFormat: CIFormat.RGBAf])
        let grain = try FilmGrain()
        let extent = CGRect(x: 0, y: 0, width: 512, height: 512)
        let seed = FilmGrain.seed(for: URL(fileURLWithPath: "/photos/density.dng"))
        let additiveAmplitude = 0.0008505
        let densityAmplitude = 8 * 0.0008505
        func image(_ level: Double, alpha: Double = 1) -> CIImage {
            CIImage(color: CIColor(red: level, green: level, blue: level, alpha: alpha, colorSpace: space.linear)!)
                .cropped(to: extent)
        }
        func pixels(_ image: CIImage) -> [Float] {
            let width = Int(image.extent.width), height = Int(image.extent.height)
            var rgba = [Float](repeating: 0, count: width * height * 4)
            context.render(image, toBitmap: &rgba, rowBytes: width * 16, bounds: image.extent,
                           format: .RGBAf, colorSpace: space.linear)
            return rgba
        }
        func red(_ image: CIImage) -> [Double] {
            let rgba = pixels(image)
            return stride(from: 0, to: rgba.count, by: 4).map { Double(rgba[$0]) }
        }
        func deviation(_ values: [Double]) -> Double {
            let mean = values.reduce(0, +) / Double(values.count)
            return sqrt(values.reduce(0) { $0 + ($1-mean)*($1-mean) } / Double(values.count))
        }
        func density(_ exposure: Double) -> Double { 0.0025 + 4 * max(0, exposure) / (max(0, exposure) + 4) }
        func positive(_ density: Double) -> Double { 1 - exp(-max(0, density)) }
        var settings = FilmGrainSettings()
        settings.output = .filmDensity
        precondition(settings.isEnabled, "Zero Strength must retain the density response")
        for level in [-0.1, 0, 0.001, 0.04, 0.18, 1, 8, 10000] {
            let values = red(try grain.apply(to: image(level), settings: settings, seed: seed))
            let expected = positive(density(level))
            precondition(values.allSatisfy { abs($0-expected) < 2e-6 }, "Incorrect zero-noise response at \(level)")
        }
        // Recover the centered field from Additive, then independently evaluate
        // the requested density model at every pixel. This also proves that
        // switching the output mode preserves the underlying RGB texture.
        for color in [0.0, 0.5, 1] {
            settings.colorScale = color
            settings.strength = 1
            settings.output = .additive
            let reference = pixels(try grain.apply(to: image(0.18), settings: settings, seed: seed))
            let blurredReference = pixels(image(0.18).clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: settings.size/2]).cropped(to: extent))
            let unit = zip(reference, blurredReference).map { Double($0-$1)/additiveAmplitude }
            settings.output = .filmDensity
            for level in [0.0, 0.04, 0.18, 0.65, 8, 10000] {
                let actual = pixels(try grain.apply(to: image(level), settings: settings, seed: seed))
                let source = pixels(image(level).clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: settings.size/2]).cropped(to: extent))
                for i in stride(from: 0, to: actual.count, by: 4) {
                    for channel in 0..<3 {
                        let j = i+channel
                        let d = density(Double(source[j]))
                        let expected = positive(d + densityAmplitude*sqrt(d)*unit[j])
                        precondition(abs(Double(actual[j])-expected) < 3e-6,
                                     "Film density must use the same normalized texture at \(level)")
                    }
                    precondition(abs(actual[i+3]-1) < 1e-6)
                }
                let values = stride(from: 0, to: actual.count, by: 4).map { Double(actual[$0]) }
                precondition(deviation(values) > 1e-5, "Black and fully developed highlights retain texture")
                precondition(actual.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1+1e-6 },
                             "Invalid output range at \(level), color \(color): \(actual.min()!), \(actual.max()!)")
            }
        }
        settings.colorScale = 0
        settings.strength = 16
        let clipped = red(try grain.apply(to: image(0), settings: settings, seed: seed))
        precondition(clipped.contains(0) && clipped.contains { $0 > 0 }, "Noisy density clamps to zero, never below")
        settings.strength = 1
        let first = red(try grain.apply(to: image(0.18), settings: settings, seed: seed))
        settings.offset = 1
        let offset = red(try grain.apply(to: image(0.18), settings: settings, seed: seed))
        precondition(offset == first,
                     "Additive Offset must not bias density noise")
        let repeated = red(try FilmGrain().apply(to: image(0.18), settings: settings, seed: seed))
        precondition(first == repeated)
        let transparent = pixels(try grain.apply(to: image(0, alpha: 0), settings: settings, seed: seed))
        precondition(transparent.allSatisfy { $0 == 0 })
        let translucent = pixels(try grain.apply(to: image(0.18, alpha: 0.5), settings: settings, seed: seed))
        for i in first.indices {
            precondition(abs(Double(translucent[4*i])-first[i]*0.5) < 1e-6)
            precondition(abs(translucent[4*i+3]-0.5) < 1e-6)
        }
        settings.strength = 0
        let transparentResponse = pixels(try grain.apply(to: image(0, alpha: 0), settings: settings))
        precondition(transparentResponse.allSatisfy { $0 == 0 })
        // Density uses source-pixel coordinates and the existing render-scale
        // contract, without a separate screen-sized or mode-specific texture.
        settings.strength = 1; settings.size = 4
        let scaled = red(try grain.apply(to: image(0.18), settings: settings, seed: seed, renderScale: 0.5))
        settings.size = 2
        let native = red(try grain.apply(to: image(0.18), settings: settings, seed: seed))
        precondition(scaled == native)
        var mapping = ToneMapping(); mapping.grain = settings
        let comparison = mapping.comparingEffects(crossProcessing: false, effects: true)
        precondition(comparison.grain == mapping.grain)
        precondition(mapping.grain.output == .filmDensity)
        precondition(SDRLUT.pointwiseMapping(mapping).grain.strength == 0, "LUTs exclude texture but retain the Analogue response")
        let worker = RAWDeveloper(colorSpace: space)
        let baselineLUT = try await worker.exportSDRLUT(mapping: comparison, dimension: 9)
        let densityLUT = try await worker.exportSDRLUT(mapping: mapping, dimension: 9)
        precondition(densityLUT == baselineLUT)
        let black = image(0)
        let bitmap = context.createCGImage(black, from: extent, format: .RGBAh, colorSpace: space.linear)!
        for strength in [0.0, 1] {
            mapping.grain.strength = strength
            for interactive in [false, true] {
                let renderer = RAWDeveloper(colorSpace: space, interactive: interactive)
                let previews = try await renderer.previews(bitmap, mapping: mapping)
                for preview in [previews.sdr, previews.hdr] {
                    let values = red(CIImage(cgImage: preview))
                    precondition(values.reduce(0, +) > 0, "Preview must retain fog even without noise")
                    if strength > 0 { precondition(deviation(values) > 1e-6) }
                }
            }
        }
        var export = HEIFSettings(); export.format = .tiff; export.tiff16Bit = true; export.tiffHDR = false
        let data = try await worker.exportImage(black, mapping: mapping, settings: export)
        let exported = red(CIImage(data: data)!)
        precondition(exported.reduce(0, +) > 0 && deviation(exported) > 1e-6)
        let recipe = DevelopmentRecipe(colorSpace: space, mapping: mapping)
        let roundTrip = try DevelopmentRecipe.decode(recipe.encoded())
        precondition(roundTrip == recipe)
        let old = Data("{\"size\":2,\"strength\":1,\"offset\":0,\"colorScale\":0.5}".utf8)
        let restored = try JSONDecoder().decode(FilmGrainSettings.self, from: old)
        precondition(restored.output == .additive, "Existing recipes must retain their original mix")
        let unknown = Data("{\"output\":\"unknown\"}".utf8)
        do { _ = try JSONDecoder().decode(FilmGrainSettings.self, from: unknown); fatalError("Unknown output accepted") }
        catch DecodingError.dataCorrupted { }
        print("PASS: density formula, shared RGB texture, fog, highlight texture, clamping, zero-noise response, alpha, source scale, compare/LUT bypass, previews/export and persistence")
    }
}
