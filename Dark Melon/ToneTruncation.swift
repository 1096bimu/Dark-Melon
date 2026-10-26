import CoreGraphics
import Foundation

nonisolated enum ToneTruncation {
    // The curve is linear-light; 254/255 refers to the encoded SDR output.
    private static let thresholds: [ProcessingColorSpace: Double] = Dictionary(uniqueKeysWithValues:
        ProcessingColorSpace.allCases.compactMap { space in
            let level = 254.0 / 255
            guard let color = CGColor(colorSpace: space.encoded, components: [level, level, level, 1]),
                  let value = color.converted(to: space.linear, intent: .relativeColorimetric, options: nil)?.components?.first else { return nil }
            return (space, Double(value))
        })

    static func applying(to mapping: ToneMapping, space: ProcessingColorSpace) -> ToneMapping {
        guard let threshold = thresholds[space] else { return mapping }
        let curve = mapping.curve(hdr: false)
        var low = 0, high = curve.values.count - 1
        while low + 1 < high {
            let middle = (low + high) / 2
            if curve.values[middle] < threshold { low = middle } else { high = middle }
        }
        let fraction = (threshold - curve.values[low]) / (curve.values[high] - curve.values[low])
        let white = max(ToneMapping.minimumRange,
                        mapping.white * (Double(low) + fraction) / Double(curve.values.count - 1))
        guard white < mapping.white else { return mapping }
        var result = mapping
        result.white = white
        result.concentration *= white / mapping.white
        result.tonePosition = min(result.tonePosition, white)
        result.setAutomaticHDRTarget()
        return result
    }
}
