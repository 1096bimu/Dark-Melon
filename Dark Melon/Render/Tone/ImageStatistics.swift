import Foundation
import Accelerate
import CoreGraphics

// MARK: - HistogramInputRange

nonisolated enum HistogramInputRange {
    static func maximum(white: Double, hdr: Bool, encoded: Bool, sourceMaximum: Double = 1) -> Double {
        encoded ? 1 : hdr ? sourceMaximum : min(sourceMaximum, 2 * max(ToneMapping.minimumRange, white))
    }
}

// MARK: - RAWSignalRange

/// A tiny per-channel tail allowance prevents isolated defects from setting RAW range.
nonisolated enum RAWSignalRange {
    static let tailFraction = 0.0001

    static func highlight(_ rgba: [Float]) -> Double? {
        var red = [Float](), green = [Float](), blue = [Float]()
        let count = rgba.count / 4
        red.reserveCapacity(count); green.reserveCapacity(count); blue.reserveCapacity(count)
        for i in stride(from: 0, to: count * 4, by: 4) where rgba[i + 3] > 0 {
            if rgba[i].isFinite { red.append(rgba[i]) }
            if rgba[i + 1].isFinite { green.append(rgba[i + 1]) }
            if rgba[i + 2].isFinite { blue.append(rgba[i + 2]) }
        }
        guard !red.isEmpty, !green.isEmpty, !blue.isEmpty else { return nil }
        func upperLimit(_ values: inout [Float]) -> Float {
            let count = values.count
            vDSP_vsort(&values, vDSP_Length(count), 1)
            let trim = Int(Double(values.count) * tailFraction)
            return values[values.count - 1 - trim]
        }
        let r = upperLimit(&red), g = upperLimit(&green), b = upperLimit(&blue)
        return Double(max(r, g, b))
    }
}

// MARK: - SDRStatistics

nonisolated struct SDRStatistics {
    let spread: Int
    let median: Int

    init?(counts: [Int]?) {
        guard let counts, counts.count == 256 else { return nil }
        let total = counts[3...252].reduce(0, +)
        guard total > 0 else { return nil }
        func percentile(_ fraction: Double) -> Int {
            let rank = Int(ceil(Double(total) * fraction))
            var accumulated = 0
            for code in 3...252 {
                accumulated += counts[code]
                if accumulated >= rank { return code }
            }
            return 252
        }
        spread = percentile(0.9) - percentile(0.1)
        median = percentile(0.5)
    }
}

// MARK: - SDRDynamicRange

/// Scene-linear interval rendered between SDR code values 3 and 250.
/// Uses only the shared tone curve, excluding Dye Response and color effects.
nonisolated enum SDRDynamicRange {
    private static let thresholds: [ProcessingColorSpace: [Double]] = Dictionary(uniqueKeysWithValues:
        ProcessingColorSpace.allCases.map { space in
            let values = [3.0 / 255, 250.0 / 255].compactMap { value -> Double? in
                guard let color = CGColor(colorSpace: space.encoded, components: [value,value,value,1]),
                      let components = color.converted(to: space.linear, intent: .relativeColorimetric, options: nil)?.components else { return nil }
                return Double(components[0])
            }
            return (space, values)
        })

    static func stops(mapping: ToneMapping, space: ProcessingColorSpace) -> Double? {
        guard let thresholds = thresholds[space], thresholds.count == 2 else { return nil }
        let curve = mapping.curve(hdr: false)
        func input(for output: Double) -> Double? {
            guard output > 0, output < curve.values.last! else { return nil }
            var low = 0, high = curve.values.count - 1
            while low + 1 < high {
                let middle = (low + high) / 2
                if curve.values[middle] < output { low = middle } else { high = middle }
            }
            let fraction = (output - curve.values[low]) / (curve.values[high] - curve.values[low])
            return curve.black + (Double(low) + fraction) / Double(curve.values.count - 1) * (curve.white - curve.black)
        }
        guard let dark = input(for: thresholds[0]), let bright = input(for: thresholds[1]),
              dark > 0, bright > dark else { return nil }
        let result = log2(bright / dark)
        return result.isFinite ? result : nil
    }
}
