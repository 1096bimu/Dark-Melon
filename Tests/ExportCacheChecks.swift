import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import Dark_Melon

@main struct ExportCacheChecks {
    static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("image.png")
        let context = CIContext(options: [.workingColorSpace: ProcessingColorSpace.sRGB.linear])
        let source = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 128, y: 96),
            "inputColor0": CIColor(red: 0.03, green: 0.12, blue: 0.35),
            "inputColor1": CIColor(red: 0.9, green: 0.7, blue: 0.6)
        ])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 128, height: 96))
        try context.writePNGRepresentation(of: source, to: file, format: .RGBA8,
                                           colorSpace: ProcessingColorSpace.sRGB.encoded)
        let store = LUTStore(directory: folder.appendingPathComponent("LUTs"))
        var cube = "LUT_3D_SIZE 2\n"
        for b in 0...1 { for g in 0...1 { for r in 0...1 { cube += "\(1-r) \(1-g) \(1-b)\n" } } }
        let lut = folder.appendingPathComponent("invert.cube")
        try cube.write(to: lut, atomically: true, encoding: .utf8)
        let id = try store.importFile(lut)
        var mapping = ToneMapping()
        mapping.lutID = id
        mapping.hdrGain = 1.01
        mapping.hdf = 0.03
        mapping.clarity = 0.1
        mapping.vignette.amount = 0.5
        let worker = RAWDeveloper(colorSpace: .sRGB, lutStore: store)
        var settings = HEIFSettings()
        settings.format = .jpeg
        settings.quality = 0.9
        let count = try await worker.encodedSize(file, mapping: mapping, settings: settings)
        let measured = try await worker.cachedExport(file, mapping: mapping, settings: settings)
        assert(count == measured.count)
        let normal = try await worker.exportHEIF(file, mapping: mapping, settings: settings)
        func bitmap(_ data: Data) -> CGImage {
            CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(data as CFData, nil)!, 0, nil)!
        }
        func pixels(_ data: Data) -> [Float] {
            let image = bitmap(data)
            var values = [Float](repeating: 0, count: image.width * image.height * 4)
            context.render(CIImage(cgImage: image), toBitmap: &values, rowBytes: image.width * 16,
                           bounds: CGRect(x: 0, y: 0, width: image.width, height: image.height),
                           format: .RGBAf, colorSpace: ProcessingColorSpace.sRGB.linear)
            return values
        }
        let delta = zip(pixels(normal), pixels(measured)).map { abs($0 - $1) }.max()!
        assert(delta < 0.03, "Cached and streaming rendering differ: \(delta)")
        // Remove dependencies after measurement. Quality and format changes must use
        // developed pixels, rather than reopen the source or evaluate the LUT again.
        let moved = folder.appendingPathComponent("moved.png")
        try FileManager.default.moveItem(at: file, to: moved)
        store.remove(id)
        let saved = try await worker.cachedExport(file, mapping: mapping, settings: settings)
        assert(saved == measured, "Save must use the exact measured bytes")
        settings.quality = 0.65
        let lowerQuality = try await worker.cachedExport(file, mapping: mapping, settings: settings)
        assert(lowerQuality != measured)
        settings.format = .tiff
        settings.tiff16Bit = true
        let tiff = try await worker.cachedExport(file, mapping: mapping, settings: settings)
        let tiffPixels = pixels(tiff)
        let deltaWithCachedLUT = zip(tiffPixels, pixels(measured)).map { abs($0 - $1) }.reduce(0, +) / Float(tiffPixels.count)
        assert(deltaWithCachedLUT < 0.015, "Format change must retain the developed LUT result")
        assert(bitmap(tiff).bitsPerComponent == 16)
        settings.scale = 0.5
        let small = try await worker.cachedExport(file, mapping: mapping, settings: settings)
        assert(bitmap(small).width == 64 && bitmap(small).height == 48)
        // Render the alternate rendition lazily, then retain it for further encodes.
        settings.tiffHDR = true
        let hdr = try await worker.cachedExport(file, mapping: mapping, settings: settings)
        assert(hdr != small)
        settings.tiff16Bit = false
        let hdr8 = try await worker.cachedExport(file, mapping: mapping, settings: settings)
        assert(bitmap(hdr8).bitsPerComponent == 8)
        settings.format = .jpeg
        settings.jpegHDR = true
        settings.quality = 0.8
        let gainJPEG = try await worker.cachedExport(file, mapping: mapping, settings: settings)
        func hasGainMap(_ data: Data) -> Bool {
            let container = CGImageSourceCreateWithData(data as CFData, nil)!
            return CGImageSourceCopyAuxiliaryDataInfoAtIndex(container, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil
        }
        assert(hasGainMap(gainJPEG))
        settings.quality = 0.6
        let gainJPEGQuality = try await worker.cachedExport(file, mapping: mapping, settings: settings)
        assert(hasGainMap(gainJPEGQuality) && gainJPEGQuality != gainJPEG)
        settings.format = .heif
        settings.heifHDRMode = .gainMap
        let gainHEIF = try await worker.cachedExport(file, mapping: mapping, settings: settings)
        assert(hasGainMap(gainHEIF))
        settings.rgbGainMap = false
        settings.halfSizeGainMap = false
        let monoGain = try await worker.cachedExport(file, mapping: mapping, settings: settings)
        assert(hasGainMap(monoGain))
        let monoSource = CGImageSourceCreateWithData(monoGain as CFData, nil)!
        let monoAux = CGImageSourceCopyAuxiliaryDataInfoAtIndex(monoSource, 0, kCGImageAuxiliaryDataTypeISOGainMap)! as NSDictionary
        let description = monoAux[kCGImageAuxiliaryDataInfoDataDescription] as! NSDictionary
        assert(description["Width"] as! Int == 64 && description["Height"] as! Int == 48)
        settings.heifHDRMode = .off
        let heifSDR = try await worker.cachedExport(file, mapping: mapping, settings: settings)
        assert(!hasGainMap(heifSDR))
        settings.heifHDRMode = .direct
        let pq = try await worker.cachedExport(file, mapping: mapping, settings: settings)
        assert(!hasGainMap(pq) && bitmap(pq).width == 64)
        try FileManager.default.moveItem(at: moved, to: file)
        settings.format = .tiff
        mapping.lutID = nil
        mapping.concentration = 0.6
        let changed = try await worker.cachedExport(file, mapping: mapping, settings: settings)
        assert(changed != hdr8, "Edit changes must invalidate the rendered cache")
        let other = folder.appendingPathComponent("other.png")
        let dark = CIImage(color: .black).cropped(to: source.extent)
        try context.writePNGRepresentation(of: dark, to: other, format: .RGBA8, colorSpace: ProcessingColorSpace.sRGB.encoded)
        let otherData = try await worker.cachedExport(other, mapping: mapping, settings: settings)
        assert(otherData != changed, "Source changes must invalidate the cache")
        print("Exact measured-file reuse, quality/format/size reuse without source or LUT, lazy HDR, edit/source invalidation, gain-map/SDR/PQ modes, bit depth and streaming parity passed.")
    }
}
