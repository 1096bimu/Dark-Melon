import CoreGraphics
import Foundation

// MARK: - AutoContrast

nonisolated enum AutoContrast {
    static func suggestion(median: Int, mapping: ToneMapping, space: ProcessingColorSpace) -> Double? {
        guard mapping.tonePosition == 0, mapping.concentration >= 0,
              median > 130 else { return nil }
        // Aim one code value inside the acceptable interval to allow rounding.
        let target = 129
        func linear(_ code: Int) -> Double? {
            let v = Double(code) / 255
            guard let color = CGColor(colorSpace: space.encoded, components: [v,v,v,1]),
                  let values = color.converted(to: space.linear, intent: .relativeColorimetric, options: nil)?.components else { return nil }
            return Double(values[0])
        }
        guard let current = linear(median), let desired = linear(target),
              current > 0, current < 1, desired > 0, desired < 1 else { return nil }
        let power = pow(257, mapping.concentration)
        let logRemainingInput = log1p(-current) / power
        let nextPower = log1p(-desired) / logRemainingInput
        if nextPower >= 1 { return min(mapping.concentration, log(nextPower) / log(257)) }
        // Negative contrast uses the normalized integral of 1 - q(1-x)^2.
        // Solve that branch directly instead of extending the positive formula.
        let x = -expm1(logRemainingInput)
        let integral = x - x*x + x*x*x/3
        let denominator = integral - desired/3
        guard denominator > 0 else { return -1 }
        return -min(1, max(0, (x-desired)/denominator))
    }
}

// MARK: - ToneTruncation

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

// MARK: - ToneISOProxy

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
