import CoreGraphics
import Foundation

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
