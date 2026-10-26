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

    init(properties: [CFString: Any], url: URL? = nil, isRAW: Bool = false, type: UTType? = nil) {
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
        fileSize = url.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.map(Int64.init)
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
    var ev100: Double? {
        guard let aperture, let exposure, let iso else { return nil }
        return log2(aperture * aperture / exposure) - log2(iso / 100)
    }
    var exposureDescription: String {
        var parts: [String] = []
        if let aperture { parts.append("ƒ/" + aperture.formatted(.number.precision(.fractionLength(1)))) }
        if let exposure {
            parts.append(exposure < 1 ? "1/\((1 / exposure).formatted(.number.precision(.fractionLength(0)))) s" : "\(exposure.formatted(.number.precision(.fractionLength(2)))) s")
        }
        if let iso { parts.append("ISO \(iso.formatted(.number.precision(.fractionLength(0))))") }
        if let focalLength { parts.append("\(focalLength.formatted(.number.precision(.fractionLength(0)))) mm") }
        return parts.isEmpty ? "Exposure metadata unavailable" : parts.joined(separator: " · ")
    }
}

struct CameraMetadataOverlay: View {
    let metadata: CameraMetadata
    let whitePoint: RAWWhitePoint?
    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let camera = metadata.camera { Text(camera).fontWeight(.medium) }
            if let lens = metadata.lens { Text(lens) }
            if let date = metadata.captureDate { Text(date, format: metadata.captureDateFormat) }
            Text(metadata.exposureDescription)
            if let ev = metadata.ev100 { Text("EV100 \(ev, format: .number.precision(.fractionLength(1)))") }
            else { Text("EV100 unavailable") }
            if let whitePoint {
                Text("WB \(whitePoint.temperature, format: .number.precision(.fractionLength(0))) K · Tint \(whitePoint.tint, format: .number.precision(.fractionLength(1)))")
            } else {
                Text("WB: \(metadata.whiteBalanceMode ?? "unavailable")")
            }
            HStack(spacing: 6) {
                if let size = metadata.fileSize { Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
                if let depth = metadata.bitDepth {
                    if metadata.bitDepthIsDecoded { Text("\(depth)-bit decoded") }
                    else { Text("\(depth)-bit") }
                }
                if let format = metadata.pixelFormat { Text(format) }
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.white)
        .padding(10)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        .modifier(PreviewOverlayVisibility())
        .padding(12)
    }
}
