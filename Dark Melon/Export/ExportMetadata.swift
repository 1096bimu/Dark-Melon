import Foundation
import ImageIO

nonisolated enum ExportMetadata {
    static let effectiveISOPreferenceKey = "export.effectiveISO"
    static var effectiveISOEnabled: Bool {
        UserDefaults.standard.object(forKey: effectiveISOPreferenceKey) as? Bool ?? true
    }

    static func read(_ url: URL) -> [String: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary) else { return [:] }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
    }

    /// Core Image's PQ encoder omits IPTC. Merge metadata without decoding or
    /// recompressing its 10-bit image, profile, or HDR signaling.
    static func retainingMetadata(in data: Data, properties: [String: Any]) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) else { throw HEIFExportError.encoding }
        let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil)
            .flatMap { CGImageMetadataCreateMutableCopy($0) } ?? CGImageMetadataCreateMutable()
        for (dictionary, value) in properties {
            guard let entries = value as? [String: Any] else { continue }
            for (key, value) in entries {
                CGImageMetadataSetValueMatchingImageProperty(metadata, dictionary as CFString, key as CFString, value as CFTypeRef)
            }
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil),
              CGImageDestinationCopyImageSource(destination, source, [
                kCGImageDestinationMetadata: metadata,
                kCGImageDestinationMergeMetadata: true
              ] as CFDictionary, nil) else { throw HEIFExportError.encoding }
        return output as Data
    }

    /// Carry descriptive metadata, not source codec, profile, thumbnail or RAW layout tags.
    static func properties(_ source: [String: Any], width: Int, height: Int,
                           mapping: ToneMapping, rawExposure: Double, effectiveISO: Bool) -> [String: Any] {
        var result: [String: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyExifAuxDictionary,
                    kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
            result[key as String] = source[key as String]
        }
        var tiff = source[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        for key in ["Compression", "PhotometricInterpretation", "BitsPerSample", "SamplesPerPixel",
                    "StripOffsets", "StripByteCounts", "RowsPerStrip", "ImageWidth", "ImageLength"] {
            tiff.removeValue(forKey: key)
        }
        tiff[kCGImagePropertyTIFFOrientation as String] = 1
        tiff[kCGImagePropertyTIFFSoftware as String] = "Dark Melon"
        result[kCGImagePropertyTIFFDictionary as String] = tiff
        result[kCGImagePropertyOrientation as String] = 1
        var exif = result[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        exif[kCGImagePropertyExifPixelXDimension as String] = width
        exif[kCGImagePropertyExifPixelYDimension as String] = height
        // The encoder supplies the selected output profile. Camera maker notes
        // contain proprietary offsets and aren't portable to a developed file.
        exif.removeValue(forKey: kCGImagePropertyExifColorSpace as String)
        exif.removeValue(forKey: kCGImagePropertyExifMakerNote as String)
        let cameraProperties = Dictionary(uniqueKeysWithValues: source.map { ($0.key as CFString, $0.value) })
        if effectiveISO, let iso = CameraMetadata(properties: cameraProperties).iso {
            let value = ToneISOProxy.displayValue(white: mapping.white, sourceISO: iso, rawExposure: rawExposure)
            if value.isFinite, value > 0 {
                let rounded = Int(min(Double(UInt32.max), max(1, value.rounded())))
                exif[kCGImagePropertyExifISOSpeedRatings as String] = [min(65535, rounded)]
                exif[kCGImagePropertyExifISOSpeed as String] = rounded
                exif[kCGImagePropertyExifSensitivityType as String] = 3
                // Keep any existing alternate ISO tags consistent with the primary rating.
                for key in [kCGImagePropertyExifISOSpeed, kCGImagePropertyExifStandardOutputSensitivity,
                            kCGImagePropertyExifRecommendedExposureIndex, kCGImagePropertyExifExposureIndex] {
                    if exif[key as String] != nil { exif[key as String] = rounded }
                }
            }
        }
        result[kCGImagePropertyExifDictionary as String] = exif
        return result
    }
}
