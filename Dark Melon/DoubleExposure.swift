import Foundation
import CoreImage
import ImageIO

/// Document-only source description. Ordinary preset/clipboard extraction omits it.
nonisolated struct DoubleExposure: Codable, Equatable, Sendable {
    var first: String
    var second: String
    var secondRAW: RAWSettings
    var secondBalance: RAWWhiteBalance?
    static func isDocument(_ url: URL) -> Bool { url.lastPathComponent.lowercased().hasSuffix(".double.darkmelon.xmp") }
    func urls(relativeTo document: URL) -> [URL] {
        [first, second].map { document.deletingLastPathComponent().appendingPathComponent($0).standardizedFileURL }
    }
    static func read(_ url: URL) -> DoubleExposure? {
        guard isDocument(url), let data = try? Data(contentsOf: url), data.count <= 8 * 1024 * 1024,
              let metadata = CGImageMetadataCreateFromXMPData(data as CFData),
              let json = CGImageMetadataCopyStringValueWithPath(metadata, nil, "darkmelon:Recipe" as CFString),
              let recipe = try? DevelopmentRecipe.decode(Data((json as String).utf8)) else { return nil }
        return recipe.mapping.doubleExposure
    }
    static func orientation(_ url: URL) -> Int32 {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return 1 }
        return (properties[kCGImagePropertyOrientation] as? NSNumber)?.int32Value ?? 1
    }
    static func sensorImage(_ image: CIImage, orientation: Int32) -> CIImage {
        let inverse: Int32 = orientation == 6 ? 8 : orientation == 8 ? 6 : orientation
        let result = image.oriented(forExifOrientation: inverse)
        return result.transformed(by: CGAffineTransform(translationX: -result.extent.minX, y: -result.extent.minY))
    }
    static func combine(_ first: CIImage, _ second: CIImage, firstOrientation: Int32, secondOrientation: Int32, firstGeometry: SourceOrientation = SourceOrientation(), secondGeometry: SourceOrientation = SourceOrientation()) throws -> CIImage {
        let firstSensor = sensorImage(first, orientation: firstOrientation)
        let secondSensor = sensorImage(second, orientation: secondOrientation)
        guard firstSensor.extent.size == secondSensor.extent.size else { throw Failure.dimensions }
        // Both exposures share Source 1's canvas orientation, but mirror independently.
        let a = firstGeometry.apply(to: firstSensor.oriented(forExifOrientation: firstOrientation))
        let commonSecond = firstGeometry.apply(to: secondSensor.oriented(forExifOrientation: firstOrientation), includeMirror: false)
        let b = secondGeometry.halfTurnsOnly.apply(to: commonSecond)
        guard let sum = MetalImageKernels.color("doubleExposureAdd")?.apply(extent: a.extent, arguments: [a,b]) else { throw Failure.invalid }
        return sum

    }
    enum Failure: LocalizedError {
        case dimensions, invalid
        var errorDescription: String? {
            switch self {
            case .dimensions: String(localized: "Double exposure requires matching sensor-oriented dimensions.")
            case .invalid: String(localized: "The double exposure sources must be two RAW files.")
            }
        }
    }
}

extension DevelopmentRecipe {
    var transferable: Self {
        var result = self
        result.mapping.doubleExposure = nil
        result.snapshots = []; result.draftSnapshot = nil
        return result
    }
    mutating func applySecondRAW(from source: ToneMapping, raw: RAWSettings?, selection: SettingsPasteSelection) {
        guard var pair = mapping.doubleExposure else { return }
        pair.secondRAW = selection.applyingRAW(raw, to: pair.secondRAW) ?? pair.secondRAW
        pair.secondRAW.orientation = pair.secondRAW.orientation.halfTurnsOnly
        if selection.contains(.rawWhiteBalance), let balance = source.rawWhiteBalance { pair.secondBalance = balance }
        mapping.doubleExposure = pair
    }
}
