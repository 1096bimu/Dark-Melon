import Foundation
import ImageIO
import SwiftUI

nonisolated struct CameraMetadata: Sendable {
    let camera: String?
    let lens: String?
    let aperture: Double?
    let exposure: Double?
    let iso: Double?
    let focalLength: Double?
    let whiteBalanceMode: String?

    init(properties: [CFString: Any]) {
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
        iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first.map { $0.doubleValue }.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        focalLength = number(kCGImagePropertyExifFocalLength)
        switch (exif[kCGImagePropertyExifWhiteBalance] as? NSNumber)?.intValue {
        case 0: whiteBalanceMode = "Auto"
        case 1: whiteBalanceMode = "Manual"
        default: whiteBalanceMode = nil
        }
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
            Text(metadata.exposureDescription)
            if let ev = metadata.ev100 { Text("EV100 \(ev, format: .number.precision(.fractionLength(1)))") }
            else { Text("EV100 unavailable") }
            if let whitePoint {
                Text("WB \(whitePoint.temperature, format: .number.precision(.fractionLength(0))) K · Tint \(whitePoint.tint, format: .number.precision(.fractionLength(1)))")
            } else {
                Text("WB: \(metadata.whiteBalanceMode ?? "unavailable")")
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.white)
        .padding(10)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        .padding(12)
        .allowsHitTesting(false)
    }
}
