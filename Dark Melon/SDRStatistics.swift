import Foundation

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
