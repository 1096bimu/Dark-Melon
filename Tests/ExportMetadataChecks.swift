import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import Dark_Melon

@main struct ExportMetadataChecks {
    static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.jpg")
        let context = CIContext()
        let image = CIImage(color: CIColor(red: 0.2, green: 0.3, blue: 0.4)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 48))
        let bitmap = context.createCGImage(image, from: image.extent)!
        let destination = CGImageDestinationCreateWithURL(source as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, bitmap, [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Test Make", kCGImagePropertyTIFFModel: "Test Camera"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifISOSpeedRatings: [200],
                kCGImagePropertyExifFNumber: 2.8, kCGImagePropertyExifExposureTime: 0.01,
                kCGImagePropertyExifDateTimeOriginal: "2026:10:24 12:34:56", kCGImagePropertyExifLensModel: "Test Lens"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 43.65, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 79.38, kCGImagePropertyGPSLongitudeRef: "W"],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCopyrightNotice: "Test Copyright"]
        ] as CFDictionary)
        assert(CGImageDestinationFinalize(destination))
        var mapping = ToneMapping()
        mapping.white = 0.5
        mapping.tonePosition = 0.183
        mapping.hdrGain = 1.01
        mapping.setAutomaticHDRTarget()
        let worker = RAWDeveloper(colorSpace: .displayP3)
        for format in ExportFormat.allCases {
            for enabled in [false, true] {
                var settings = HEIFSettings()
                settings.format = format; settings.scale = 0.5; settings.effectiveISO = enabled
                for hdr in [false, true] {
                    settings.jpegHDR = hdr
                    settings.heifHDRMode = hdr ? .gainMap : .off
                    settings.tiffHDR = hdr
                    let bytes = try await worker.cachedExport(source, mapping: mapping, settings: settings)
                    check(bytes, iso: enabled ? 400 : 200)
                    if hdr && format != .tiff {
                        let encoded = CGImageSourceCreateWithData(bytes as CFData, nil)!
                        assert(CGImageSourceCopyAuxiliaryDataInfoAtIndex(encoded, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil)
                    }
                    print("PASS: \(format) gain map/HDR \(hdr), Effective ISO \(enabled)")
                }
                if format == .heif {
                    settings.heifHDRMode = .direct
                    let bytes = try await worker.cachedExport(source, mapping: mapping, settings: settings)
                    check(bytes, iso: enabled ? 400 : 200)
                    let encoded = CGImageSourceCreateWithData(bytes as CFData, nil)!
                    let properties = CGImageSourceCopyPropertiesAtIndex(encoded, 0, nil)! as NSDictionary
                    assert((properties[kCGImagePropertyDepth] as! NSNumber).intValue == 10)
                    assert((properties[kCGImagePropertyProfileName] as! String).contains("PQ"))
                    assert(CIImage(data: bytes, options: [.expandToHDR: true])!.contentHeadroom > 1)
                    print("PASS: PQ HEIF, Effective ISO \(enabled)")
                }
            }
        }
        // The uncached/batch path uses the same metadata handling.
        var settings = HEIFSettings(); settings.format = .jpeg; settings.scale = 0.5; settings.effectiveISO = true
        let batch = try await worker.exportHEIF(source, mapping: mapping, settings: settings)
        check(batch, iso: 400)
        let properties = ExportMetadata.read(source)
        let adjusted = ExportMetadata.properties(properties, width: 32, height: 24, mapping: mapping,
                                                  rawExposure: -1, effectiveISO: true)
        let exif = adjusted[kCGImagePropertyExifDictionary as String] as! [String: Any]
        assert((exif[kCGImagePropertyExifISOSpeedRatings as String] as! [NSNumber])[0].intValue == 200)
        let original = ExportMetadata.read(source)[kCGImagePropertyExifDictionary as String] as! [String: Any]
        assert((original[kCGImagePropertyExifISOSpeedRatings as String] as! [NSNumber])[0].intValue == 200)
        var highISO = properties
        var highExif = highISO[kCGImagePropertyExifDictionary as String] as! [String: Any]
        highExif[kCGImagePropertyExifISOSpeedRatings as String] = [65535]
        highExif[kCGImagePropertyExifISOSpeed as String] = 100000
        highISO[kCGImagePropertyExifDictionary as String] = highExif
        let high = ExportMetadata.properties(highISO, width: 32, height: 24, mapping: mapping,
                                               rawExposure: 0, effectiveISO: true)
        let camera = CameraMetadata(properties: Dictionary(uniqueKeysWithValues: high.map { ($0.key as CFString, $0.value) }))
        assert(camera.iso == 200000)
        settings.effectiveISO = false
        let frozen = try JSONDecoder().decode(HEIFSettings.self, from: JSONEncoder().encode(settings))
        assert(!frozen.effectiveISO)
        print("PASS: batch path, RAW exposure formula, extended ISO, frozen preference, unchanged original metadata")
    }

    static func check(_ data: Data, iso: Int) {
        let container = CGImageSourceCreateWithData(data as CFData, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(container, 0, nil)! as NSDictionary
        let exif = properties[kCGImagePropertyExifDictionary] as! NSDictionary
        let tiff = properties[kCGImagePropertyTIFFDictionary] as! NSDictionary
        let gps = properties[kCGImagePropertyGPSDictionary] as! NSDictionary
        let iptc = properties[kCGImagePropertyIPTCDictionary] as! NSDictionary
        assert((properties[kCGImagePropertyPixelWidth] as! NSNumber).intValue == 32)
        assert((properties[kCGImagePropertyPixelHeight] as! NSNumber).intValue == 24)
        assert((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1 == 1)
        assert((exif[kCGImagePropertyExifISOSpeedRatings] as! [NSNumber])[0].intValue == iso)
        assert(exif[kCGImagePropertyExifLensModel] as? String == "Test Lens")
        assert(exif[kCGImagePropertyExifDateTimeOriginal] as? String == "2026:10:24 12:34:56")
        assert(abs((exif[kCGImagePropertyExifFNumber] as! NSNumber).doubleValue - 2.8) < 0.001)
        assert(tiff[kCGImagePropertyTIFFModel] as? String == "Test Camera")
        assert(abs((gps[kCGImagePropertyGPSLatitude] as! NSNumber).doubleValue - 43.65) < 0.001)
        assert(iptc[kCGImagePropertyIPTCCopyrightNotice] as? String == "Test Copyright")
    }
}
