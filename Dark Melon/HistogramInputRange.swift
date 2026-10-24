import Foundation

nonisolated enum HistogramInputRange {
    static func maximum(white: Double, hdr: Bool, encoded: Bool) -> Double {
        hdr || encoded ? 1 : min(1, 2 * max(ToneMapping.minimumRange, white))
    }
}
