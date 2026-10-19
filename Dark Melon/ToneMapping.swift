import Foundation

nonisolated struct ToneMapping: Codable, Equatable, Sendable {
    var whiteBalance = WhiteBalance()
    var blackAndWhite = BlackAndWhiteSettings()
    var color = ColorAdjustments()
    var hls = [HLSAdjustment](repeating: HLSAdjustment(), count: 6)
    var clarity = 0.0
    var clarityRadius = 30.0
    var hdf = 0.0
    var hdfRadius = 100.0
    var grain = FilmGrainSettings()
    var black = 0.0
    var white = 1.0
    var tonePosition = 0.0
    var peakPosition: Double { black + tonePosition * (white - black) }
    var concentration = 0.2
    var hdrMax = 4.0
    var hdrEnabled: Bool { hdrMax > 1 }
    var hdrConcentrationOffset = 0.0

    var hdrConcentration: Double {
        min(1, max(-1, concentration + hdrConcentrationOffset))
    }
    static let minimumRange = 1.0 / 2048

    var hdrFallsBelowSDR: Bool {
        guard hdrEnabled else { return false }
        let sdr = curve(hdr: false), hdr = curve(hdr: true)
        // Both curves are piecewise linear. Check their combined knot positions
        // so a narrow crossing cannot slip between uniformly spaced samples.
        for curve in [sdr, hdr] {
            for index in curve.values.indices {
                let input = curve.black + (curve.white - curve.black)
                    * Double(index) / Double(curve.values.count - 1)
                if hdr.value(at: input) + 0.000001 < sdr.value(at: input) { return true }
            }
        }
        return false
    }

    func curve(hdr: Bool) -> ToneCurve {
        let hdr = hdr && hdrEnabled
        let upperInput = hdr ? 1.0 : white
        let outputMax = hdr ? hdrMax : 1.0
        let span = max(Self.minimumRange, upperInput - black)
        let count = 2000
        let effectiveConcentration = hdr ? hdrConcentration : concentration
        guard effectiveConcentration != 0 else {
            return ToneCurve(values: (0...count).map { Double($0) / Double(count) * outputMax },
                             black: black, white: upperInput)
        }
        let sharedPeak = min(white, max(black, peakPosition))
        let peak = min(1, max(0, (sharedPeak - black) / span))
        // Beta(alpha = 1 + k*p, beta = 1 + k*(1-p)). Its mode is p.
        // Exponential slider spacing gives finer control near the linear end.
        // Negative contrast subtracts a broad beta-shaped slope profile.
        // Its nonnegative density preserves monotonicity without singular endpoints.
        let negative = effectiveConcentration < 0
        let k = negative ? 2.0 : expm1(log(257) * min(1, effectiveConcentration))
        let a = k * peak
        let b = k * (1 - peak)
        let peakLog = (a == 0 ? 0 : a * log(peak))
                    + (b == 0 ? 0 : b * log1p(-peak))
        func density(_ x: Double) -> Double {
            let profile = exp(a * log(x) + b * log1p(-x) - peakLog)
            return negative ? max(0, 1 - min(1, -effectiveConcentration) * profile) : profile
        }
        // Midpoint integration avoids sampling endpoint singular limits as k
        // approaches zero. Subtracting peakLog keeps all weights well scaled.
        var values = [Double](repeating: 0, count: count + 1)
        for i in 0..<count {
            let x0 = (Double(i) + 0.25) / Double(count)
            let x1 = (Double(i) + 0.75) / Double(count)
            values[i + 1] = values[i] + (density(x0) + density(x1)) / (2 * Double(count))
        }
        let scale = outputMax / values[count]
        return ToneCurve(values: values.map { $0 * scale }, black: black, white: upperInput)
    }
}

nonisolated struct ToneCurve {
    let values: [Double]
    let black: Double
    let white: Double

    func value(at input: Double) -> Double {
        let normalized = (input - black) / max(ToneMapping.minimumRange, white - black)
        if normalized <= 0 { return 0 }
        if normalized >= 1 { return values.last! }
        let position = normalized * Double(values.count - 1)
        let index = min(values.count - 2, Int(position))
        return values[index] + (values[index + 1] - values[index]) * (position - Double(index))
    }
}
