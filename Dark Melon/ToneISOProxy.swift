import Foundation

/// A White/Tone proxy. RAW exposure contributes only to its displayed value.
nonisolated enum ToneISOProxy {
    static let range = 0.0 ... 5.0

    static func exposure(white: Double) -> Double {
        -log2(white.clamped(to: ToneMapping.minimumRange...1))
    }

    static func displayValue(white: Double, sourceISO: Double?, rawExposure: Double) -> Double {
        let ev = rawExposure + exposure(white: white)
        return sourceISO.map { $0 * exp2(ev) } ?? ev
    }

    static func adjustment(displayValue: Double, sourceISO: Double?, rawExposure: Double) -> Double {
        (sourceISO.map { log2(displayValue / $0) } ?? displayValue) - rawExposure
    }

    static func displayRange(sourceISO: Double?, rawExposure: Double) -> ClosedRange<Double> {
        let lower = displayValue(white: 1, sourceISO: sourceISO, rawExposure: rawExposure)
        let upper = displayValue(white: exp2(-range.upperBound), sourceISO: sourceISO, rawExposure: rawExposure)
        return lower...upper
    }

    static func applying(exposure: Double, to mapping: ToneMapping) -> ToneMapping {
        let white = exp2(-exposure.clamped(to: range))
        var result = mapping
        result.white = white
        result.tonePosition = (mapping.tonePosition * white / mapping.white).clamped(to: 0...white)
        result.setAutomaticHDRTarget()
        return result
    }
}
