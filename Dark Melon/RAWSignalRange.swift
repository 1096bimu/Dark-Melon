import Foundation
import Accelerate

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
