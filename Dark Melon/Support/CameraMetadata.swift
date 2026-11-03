import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

nonisolated struct CameraMetadata: Sendable {
    let camera: String?
    let lens: String?
    let aperture: Double?
    let exposure: Double?
    let iso: Double?
    let focalLength: Double?
    let whiteBalanceMode: String?
    let captureDate: Date?
    let captureTimeZone: TimeZone
    let fileSize: Int64?
    let bitDepth: Int?
    let bitDepthIsDecoded: Bool
    let pixelFormat: String?

    init(properties: [CFString: Any], url: URL? = nil, isRAW: Bool = false, type: UTType? = nil, fileSizeURL: URL? = nil) {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        camera = tiff[kCGImagePropertyTIFFModel] as? String
        lens = exif[kCGImagePropertyExifLensModel] as? String
        func number(_ key: CFString) -> Double? {
            guard let value = (exif[key] as? NSNumber)?.doubleValue, value.isFinite, value > 0 else { return nil }
            return value
        }
        aperture = number(kCGImagePropertyExifFNumber)
        exposure = number(kCGImagePropertyExifExposureTime)
        let rating = (exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first?.doubleValue
        let extended = number(kCGImagePropertyExifISOSpeed)
        iso = (rating == nil || rating == 65535 ? extended ?? rating : rating)
            .flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        focalLength = number(kCGImagePropertyExifFocalLength)
        switch (exif[kCGImagePropertyExifWhiteBalance] as? NSNumber)?.intValue {
        case 0: whiteBalanceMode = String(localized: "Auto")
        case 1: whiteBalanceMode = String(localized: "Manual")
        default: whiteBalanceMode = nil
        }
        let timestamp = exif[kCGImagePropertyExifDateTimeOriginal] as? String
            ?? exif[kCGImagePropertyExifDateTimeDigitized] as? String
            ?? tiff[kCGImagePropertyTIFFDateTime] as? String
        let offset = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String
            ?? exif[kCGImagePropertyExifOffsetTimeDigitized] as? String
            ?? exif[kCGImagePropertyExifOffsetTime] as? String
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        // Keep the camera's wall-clock time even when the photo was taken in another zone.
        captureTimeZone = Self.timeZone(offset) ?? TimeZone(secondsFromGMT: 0)!
        formatter.timeZone = captureTimeZone
        captureDate = timestamp.flatMap(formatter.date(from:))
        fileSize = (fileSizeURL ?? url).flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.map(Int64.init)
        let heif = type?.conforms(to: .heif) == true || type?.conforms(to: .heic) == true
        let storedFormat: ImageFileMetadata.Format?
        if heif { storedFormat = url.flatMap(ImageFileMetadata.heif) }
        else if type?.conforms(to: .jpeg) == true { storedFormat = url.flatMap(ImageFileMetadata.jpeg) }
        else { storedFormat = nil }
        let rawDepth = isRAW ? url.flatMap(ImageFileMetadata.rawBitDepth) : nil
        bitDepth = rawDepth ?? storedFormat?.bitDepth ?? (properties[kCGImagePropertyDepth] as? NSNumber)?.intValue
        bitDepthIsDecoded = isRAW && rawDepth == nil && bitDepth != nil
        pixelFormat = isRAW ? "RAW" : storedFormat?.name
            ?? (heif ? "HEIF" : properties[kCGImagePropertyColorModel] as? String)
    }
    var captureDateFormat: Date.FormatStyle {
        var format = Date.FormatStyle(date: .abbreviated, time: .standard)
        format.timeZone = captureTimeZone
        return format
    }
    private static func timeZone(_ value: String?) -> TimeZone? {
        guard let value else { return nil }
        let parts = value.dropFirst().split(separator: ":")
        guard value.first == "+" || value.first == "-", parts.count == 2,
              let hours = Int(parts[0]), let minutes = Int(parts[1]),
              (0...23).contains(hours), (0...59).contains(minutes) else { return nil }
        return TimeZone(secondsFromGMT: (hours * 3600 + minutes * 60) * (value.first == "-" ? -1 : 1))
    }
}
