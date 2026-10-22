import CoreGraphics
import Foundation

/// Fits the selected input shade in SDR while keeping its source luminance fixed.
/// Tone is stored directly in source-linear luminance.
nonisolated enum ToneSampleWhitePoint {
    static func automaticTones(mapping: ToneMapping, space: ProcessingColorSpace) -> ToneMapping {
        var result = mapping
        let input = mapping.peakPosition
        let shade = SIMD3<Double>(repeating: input)
        result.white = adjustedWhite(sample: shade, mapping: mapping, space: space)
        return result
    }

    static func adjustedWhite(sample: SIMD3<Double>, mapping: ToneMapping,
                              space: ProcessingColorSpace) -> Double {
        let input = mapping.peakPosition
        let weights = space.luminance

        func level(_ white: Double) -> Double {
            var candidate = mapping
            candidate.white = white
            let curve = candidate.curve(hdr: false)
            let toned = [sample.x, sample.y, sample.z].map { CGFloat(curve.value(at: $0)) }
            guard let color = CGColor(colorSpace: space.linear, components: toned + [1]),
                  let rgb = color.converted(to: space.encoded, intent: .relativeColorimetric,
                                            options: nil)?.components else { return .nan }
            return (rgb[0] * weights.x + rgb[1] * weights.y + rgb[2] * weights.z) * 255
        }

        let current = level(mapping.white)
        guard current.isFinite, current < 120 - 0.00001 || current > 140 + 0.00001 else { return mapping.white }
        let minimum = min(1, max(input, ToneMapping.minimumRange))
        let target = current < 120 ? 120.0 : 140.0
        let endpoint = current < 120 ? minimum : 1.0
        let endLevel = level(endpoint)
        guard endLevel.isFinite else { return mapping.white }
        guard current < 120 ? endLevel > current : endLevel < current else { return mapping.white }
        // If the valid white-point range cannot reach the target, take the closest achievable result.
        if current < 120 && endLevel < target || current > 140 && endLevel > target { return endpoint }

        var lower = min(mapping.white, endpoint)
        var upper = max(mapping.white, endpoint)
        // SDR output decreases monotonically as white increases. Find the nearest
        // boundary of the acceptable band, rather than aiming for its midpoint.
        for _ in 0..<32 {
            let middle = (lower + upper) / 2
            if level(middle) > target { lower = middle }
            else { upper = middle }
        }
        return current < 120 ? lower : upper
    }
}
