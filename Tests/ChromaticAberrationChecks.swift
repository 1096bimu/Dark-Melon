import Foundation
import CoreImage
@testable import Dark_Melon

@main struct ChromaticAberrationChecks {
    static func main() async throws {
        let space = ProcessingColorSpace.sRGB
        let context = CIContext(options: [.workingColorSpace: space.linear, .workingFormat: CIFormat.RGBAf])
        let width = 240, height = 160
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        var values = [Float]()
        for y in 0..<height { for x in 0..<width {
            values += [Float(Double(x)+0.5)/Float(width), Float(Double(y)+0.5)/Float(height),
                       Float(Double(x+y)+1)/Float(width+height), 1]
        } }
        let source = CIImage(bitmapData: values.withUnsafeBytes { Data($0) }, bytesPerRow: width*16,
            size: bounds.size, format: .RGBAf, colorSpace: space.linear)
        func pixels(_ image: CIImage) -> [Float] {
            let w = Int(image.extent.width), h = Int(image.extent.height)
            var output = [Float](repeating: 0, count: w*h*4)
            context.render(image, toBitmap: &output, rowBytes: w*16, bounds: image.extent, format: .RGBAf, colorSpace: space.linear)
            return output
        }
        let renderer = DustCorrection()
        let identity = try renderer.apply(source, spots: [], geometry: DustGeometry())
        precondition(identity === source)
        let correction = ChromaticAberration(red: 5, blue: -5)
        let aligned = try renderer.apply(source, spots: [], geometry: DustGeometry(), chromaticAberration: correction)
        let actual = pixels(aligned)
        for y in stride(from: 10, to: height-10, by: 7) { for x in stride(from: 10, to: width-10, by: 7) {
            let i = (y*width+x)*4
            let px = Double(x)+0.5, py = Double(y)+0.5
            let rx = 120+(px-120)/1.05
            let bx = 120+(px-120)/0.95, by = 80+(py-80)/0.95
            precondition(abs(Double(actual[i])-rx/240) < 1e-5)
            precondition(actual[i+1] == values[i+1], "Green must stay fixed")
            precondition(abs(Double(actual[i+2])-(bx+by)/400) < 1e-5)
            precondition(actual[i+3] == 1)
        } }
        // The warp is defined against the full image, never a detail patch.
        let patch = CGRect(x: 15, y: 20, width: 61, height: 47)
        let crop = pixels(aligned.cropped(to: patch))
        for y in 0..<47 { for x in 0..<61 { for c in 0..<4 {
            precondition(abs(crop[(y*61+x)*4+c]-actual[((y+height-20-47)*width+x+15)*4+c]) < 1e-6, "ROI mismatch x \(x) y \(y) c \(c): \(crop[(y*61+x)*4+c]) vs \(actual[((y+height-20-47)*width+x+15)*4+c])")
        } } }
        let shifted = source.transformed(by: CGAffineTransform(translationX: 13, y: -27))
        let shiftedResult = pixels(try renderer.apply(shifted, spots: [], geometry: DustGeometry(), chromaticAberration: correction))
        precondition(zip(shiftedResult, actual).allSatisfy { abs($0-$1) < 1e-6 })
        let flat = CIImage(color: CIColor(red: 0.4, green: 0.3, blue: 0.2, colorSpace: space.linear)!).cropped(to: bounds)
        let flatPixels = pixels(try renderer.apply(flat, spots: [], geometry: DustGeometry(), chromaticAberration: correction))
        precondition(stride(from: 0, to: flatPixels.count, by: 4).allSatisfy { abs(flatPixels[$0]-0.4) < 1e-6 && flatPixels[$0+3] == 1 }, "Edges must clamp without black or transparent borders")
        for alpha in [0.0, 0.5] {
            let transparent = CIImage(color: CIColor(red: 4, green: 2, blue: 8, alpha: alpha, colorSpace: space.linear)!).cropped(to: bounds)
            let rgba = pixels(try renderer.apply(transparent, spots: [], geometry: DustGeometry(), chromaticAberration: correction))
            for i in stride(from: 0, to: rgba.count, by: 4) {
                for (c, value) in [4.0,2,8,1].enumerated() { precondition(abs(Double(rgba[i+c])-value*alpha) < 1e-6) }
            }
        }
        var spot = DustSpot(center: CGPoint(x: 0.3, y: 0.6)); spot.radius = 0.15; spot.feather = 0.1; spot.attenuation = 0.4
        let together = pixels(try renderer.apply(source, spots: [spot], geometry: DustGeometry(), chromaticAberration: correction))
        let sequential = pixels(try renderer.apply(aligned, spots: [spot], geometry: DustGeometry()))
        precondition(zip(together, sequential).allSatisfy { abs($0-$1) < 1e-5 }, "Align channels before evaluating dust attenuation")
        var mapping = ToneMapping(); mapping.chromaticAberration = correction; mapping.dustSpots = [spot]
        let recipe = DevelopmentRecipe(colorSpace: space, mapping: mapping)
        let restored = try DevelopmentRecipe.decode(recipe.encoded())
        precondition(restored == recipe)
        let pasted = SettingsPasteSelection(items: [.chromaticAberration]).applying(mapping, to: ToneMapping())
        precondition(pasted.chromaticAberration == correction && pasted.dustSpots == nil)
        precondition(SDRLUT.pointwiseMapping(mapping).chromaticAberration.isIdentity)
        precondition(ToneMapping().chromaticAberration.isIdentity)
        for invalid in [Double.nan, -5.01, 5.01] {
            var bad = recipe; bad.mapping.chromaticAberration.red = invalid
            do { _ = try DevelopmentRecipe.decode(bad.encoded()); fatalError("Invalid correction accepted") }
            catch { }
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("source.tiff")
        try context.writeTIFFRepresentation(of: source, to: url, format: .RGBAh, colorSpace: space.linear)
        let worker = RAWDeveloper(colorSpace: space, interactive: true)
        let clean = try await worker.develop(url)
        let baked = try await worker.develop(url, dustSpots: [spot], chromaticAberration: correction)
        let expected = pixels(try renderer.apply(clean.linearSource, spots: [spot], geometry: clean.dustGeometry, chromaticAberration: correction))
        precondition(zip(pixels(baked.linearSource), expected).allSatisfy { abs($0-$1) < 0.002 })
        precondition(baked.chromaticAberration == correction && baked.matchesSourceCorrections(mapping))
        let stamp = RAWImageCache.FileStamp(url)!
        precondition(RAWImageCache.shared.lookup(stamp, space: space, settings: nil, balance: nil, dustSpots: [spot], chromaticAberration: correction) != nil)
        precondition(RAWImageCache.shared.lookup(stamp, space: space, settings: nil, balance: nil, dustSpots: [spot]) == nil)
        let progressive = try await worker.develop(url, previewCanvas: CGSize(width: 120, height: 80), progressive: true,
            dustSpots: [], chromaticAberration: correction)
        precondition(progressive.chromaticAberration == correction)
        let full = try await worker.prepareFullResolution(progressive)
        let fullExpected = pixels(try renderer.apply(clean.linearSource, spots: [], geometry: clean.dustGeometry, chromaticAberration: correction))
        precondition(zip(pixels(full.linearSource), fullExpected).allSatisfy { abs($0-$1) < 0.002 })
        let removed = try await worker.replacingSourceCorrections(full, spots: [], canvas: bounds.size, chromaticAberration: ChromaticAberration())
        precondition(removed.chromaticAberration.isIdentity)
        precondition(zip(pixels(removed.linearSource), pixels(clean.linearSource)).allSatisfy { abs($0-$1) < 0.001 })
        // URL exports bake the correction once; preview rendering consumes baked pixels.
        mapping.grain.output = .additive
        var settings = HEIFSettings(); settings.format = .tiff; settings.tiff16Bit = true; settings.tiffHDR = false
        let output = try await worker.exportHEIF(url, mapping: mapping, settings: settings)
        var downstream = mapping; downstream.dustSpots = nil; downstream.chromaticAberration = ChromaticAberration()
        let reference = try await worker.exportImage(baked.linearSource, mapping: downstream, settings: settings)
        let a = pixels(CIImage(data: output)!), b = pixels(CIImage(data: reference)!)
        precondition(zip(a,b).allSatisfy { abs($0-$1) < 0.003 }, "Export must align before dust exactly once")
        print("PASS: channel scale and center, fixed green, translated/detail ROI, edge clamping, pre-dust order, persistence/paste, validation, cache keys, source rebuild/full resolution, removal and export")
    }
}
