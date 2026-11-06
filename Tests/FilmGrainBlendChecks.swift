import Foundation
import CoreImage
@testable import Dark_Melon

@main struct FilmGrainBlendChecks {
    static func main() async throws {
        let space = ProcessingColorSpace.sRGB
        let context = CIContext(options: [.workingColorSpace: space.linear, .workingFormat: CIFormat.RGBAf])
        let grain = try FilmGrain()
        let extent = CGRect(x: 0, y: 0, width: 512, height: 512)
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
        func stats(_ values: [Double]) -> (mean: Double, deviation: Double) {
            let mean = values.reduce(0, +) / Double(values.count)
            let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
            return (mean, sqrt(variance))
        }
        let url = URL(fileURLWithPath: "/photos/a.dng")
        let seed = FilmGrain.seed(for: url)
        precondition(seed == FilmGrain.seed(for: url))
        precondition(seed == FilmGrain.seed(for: URL(fileURLWithPath: "/photos/../photos/a.dng")))
        precondition(seed != FilmGrain.seed(for: URL(fileURLWithPath: "/photos/b.dng")))
        var settings = FilmGrainSettings(); settings.strength = 1; settings.colorScale = 0
        let neutral = image(0.18)
        let output = try grain.apply(to: neutral, settings: settings, seed: seed)
        let base = red(output)
        let summary = stats(base)
        precondition(abs(summary.mean - 0.18) < 1e-6)
        precondition(abs(summary.deviation - 0.0008505) < 1e-6, "Digital Strength 1 must equal playground Strength 1")
        precondition(context.createCGImage(output, from: extent) != nil)
        for level in [0.04, 0.65, 1.5] {
            let values = red(try grain.apply(to: image(level), settings: settings, seed: seed))
            precondition(zip(values, base).allSatisfy { abs(($0-level)-($1-0.18)) < 1e-6 })
        }
        let black = image(0)
        let blackValues = red(try grain.apply(to: black, settings: settings, seed: seed))
        precondition(zip(blackValues, base).allSatisfy { abs($0-max($1-0.18,0)) < 1e-6 })
        precondition(blackValues.contains(0) && blackValues.contains { $0 > 0 })
        let repeated = red(try FilmGrain().apply(to: neutral, settings: settings, seed: seed))
        precondition(repeated == base, "Repeated exports retain the same pattern")
        let different = red(try grain.apply(to: neutral, settings: settings, seed: FilmGrain.seed(for: URL(fileURLWithPath: "/photos/b.dng"))))
        precondition(zip(different, base).contains { abs($0-$1) > 0.001 })
        settings.strength = 2
        let twice = red(try grain.apply(to: neutral, settings: settings, seed: seed))
        precondition(zip(twice, base).allSatisfy { abs(($0-0.18)-2*($1-0.18)) < 1e-6 })
        settings.strength = 0
        let untouched = try grain.apply(to: neutral, settings: settings, seed: seed)
        precondition(untouched === neutral)
        settings.strength = 1
        for offset in [-1.0, -0.5, 0, 0.5, 1] {
            settings.offset = offset
            let values = red(try grain.apply(to: neutral, settings: settings, seed: seed))
            precondition(values.allSatisfy(\.isFinite))
            if offset == 1 { precondition(values.allSatisfy { $0 >= 0.18-1e-6 }) }
            if offset == -1 { precondition(values.allSatisfy { $0 <= 0.18+1e-6 }) }
        }
        settings.offset = 0
        let transparent = pixels(try grain.apply(to: image(0, alpha: 0), settings: settings, seed: seed))
        precondition(transparent.allSatisfy { $0 == 0 })
        let translucent = pixels(try grain.apply(to: image(0.18, alpha: 0.5), settings: settings, seed: seed))
        for i in base.indices {
            precondition(abs(Double(translucent[4*i])-base[i]*0.5) < 1e-6)
            precondition(abs(translucent[4*i+3] - 0.5) < 1e-6)
        }
        for color in [0.0, 0.5, 1.0] {
            settings.colorScale = color
            let rgba = pixels(try grain.apply(to: neutral, settings: settings, seed: seed))
            let differences = stride(from: 0, to: rgba.count, by: 4).map { Double(rgba[$0]-rgba[$0+1]) }
            if color == 0 { precondition(differences.allSatisfy { abs($0) < 1e-6 }) }
            else { precondition(stats(differences).deviation > 1e-6) }
        }
        // The source is blurred at size/2 source pixels, without another resolution multiplier.
        let detail = CIFilter(name: "CICheckerboardGenerator", parameters: [
            "inputWidth": 1.0, "inputSharpness": 1.0,
            "inputColor0": CIColor(red: 0.1, green: 0.1, blue: 0.1),
            "inputColor1": CIColor(red: 0.8, green: 0.8, blue: 0.8)
        ])!.outputImage!.cropped(to: extent)
        settings.colorScale = 0
        for size in [1.0, 2, 4, 8] {
            settings.size = size
            let values = red(try grain.apply(to: detail, settings: settings, seed: seed))
            let flat = red(try grain.apply(to: neutral, settings: settings, seed: seed))
            let blurred = red(detail.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: size/2
            ]).cropped(to: extent))
            let flatBase = red(neutral.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: size/2
            ]).cropped(to: extent))
            // Core Image's larger Gaussian kernels have finite DC precision;
            // subtract the actual blurred reference rather than assuming 0.18.
            let maxError = zip(zip(zip(values, flat), blurred), flatBase).map {
                abs($0.0.0-max($0.1+$0.0.1-$1, 0))
            }.max()!
            precondition(maxError < 1e-6)
        }
        // One shared stage is used by both preview paths and TIFF export.
        settings.size = 1; settings.offset = 1
        var mapping = ToneMapping(); mapping.grain = settings
        let bitmap = context.createCGImage(black, from: extent, format: .RGBAh, colorSpace: space.linear)!
        for interactive in [false, true] {
            let worker = RAWDeveloper(colorSpace: space, interactive: interactive)
            let previews = try await worker.previews(bitmap, mapping: mapping, sourceURL: url)
            precondition(stats(red(CIImage(cgImage: previews.sdr))).deviation > 0)
            precondition(stats(red(CIImage(cgImage: previews.hdr))).deviation > 0)
        }
        let worker = RAWDeveloper(colorSpace: space)
        var export = HEIFSettings(); export.format = .tiff; export.tiff16Bit = true; export.tiffHDR = false
        let encoded = try await worker.exportImage(black, mapping: mapping, settings: export)
        precondition(stats(red(CIImage(data: encoded)!)).deviation > 0)
        // The real URL-driven export path must seed new workers identically.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fileA = folder.appendingPathComponent("a.tiff"), fileB = folder.appendingPathComponent("b.tiff")
        var plain = mapping; plain.grain.strength = 0
        let sourceData = try await worker.exportImage(black, mapping: plain, settings: export)
        try sourceData.write(to: fileA); try sourceData.write(to: fileB)
        let first = try await RAWDeveloper(colorSpace: space).exportHEIF(fileA, mapping: mapping, settings: export)
        let second = try await RAWDeveloper(colorSpace: space).exportHEIF(fileA, mapping: mapping, settings: export)
        let other = try await RAWDeveloper(colorSpace: space).exportHEIF(fileB, mapping: mapping, settings: export)
        let firstPixels = red(CIImage(data: first)!)
        precondition(firstPixels == red(CIImage(data: second)!))
        precondition(firstPixels != red(CIImage(data: other)!))
        // Large logical images render a small visible crop without a full-size noise cache.
        let largeExtent = CGRect(x: 0, y: 0, width: 12000, height: 9000)
        let large = CIImage(color: CIColor(red: 0.18, green: 0.18, blue: 0.18, colorSpace: space.linear)!).cropped(to: largeExtent)
        let result = try grain.apply(to: large, settings: settings, seed: seed)
        precondition(result.extent == largeExtent)
        let corner = result.cropped(to: CGRect(x: 11000, y: 8000, width: 128, height: 128))
        let cornerPixels = red(corner)
        precondition(cornerPixels.allSatisfy(\.isFinite) && stats(cornerPixels).deviation > 0)
        let old = Data("{\"size\":0.5,\"strength\":4,\"distribution\":0.9}".utf8)
        let restored = try JSONDecoder().decode(FilmGrainSettings.self, from: old)
        precondition(restored.size == 2 && restored.strength == 4 && restored.offset == 0 && restored.colorScale == 0.5)
        let saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as! [String: Any]
        precondition(saved["distribution"] == nil && saved["offset"] != nil && saved["colorScale"] != nil)
        let recipe = DevelopmentRecipe(colorSpace: space, mapping: mapping)
        let roundTrip = try DevelopmentRecipe.decode(recipe.encoded())
        precondition(roundTrip == recipe)
        for value in [Double.nan, -1, 1.1] {
            var invalid = recipe; invalid.mapping.grain.colorScale = value
            do { _ = try DevelopmentRecipe.decode(invalid.encoded()); fatalError("Invalid color scale accepted") }
            catch { }
        }
        print("PASS: strength scaling, signed blend and offsets, stable file seed, RGB scale, blur, alpha, size, preview/export, persistence and bounds")
    }
}
