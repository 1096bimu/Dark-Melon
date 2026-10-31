import Foundation

nonisolated enum HistogramInputRange {
    static func maximum(white: Double, hdr: Bool, encoded: Bool, sourceMaximum: Double = 1) -> Double {
        encoded ? 1 : hdr ? sourceMaximum : min(sourceMaximum, 2 * max(ToneMapping.minimumRange, white))
    }
}
