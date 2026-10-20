import Foundation

nonisolated struct ToneMapping: Codable, Equatable, Sendable {
    var whiteBalance = WhiteBalance()
    var rawWhiteBalance: RAWWhiteBalance?
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
    var hdrTarget = 4.0
    var hdrGain = 1.0
    var hdrRolloff = 0.0
    var hdrEnabled: Bool { hdrGain > 0 }
    /// Rendering headroom and effect ceilings must cover the multiplied curve.
    var hdrMax: Double {
        guard hdrEnabled else { return 1 }
        let start = curve(hdr: false).value(at: peakPosition)
        let endpoint = hdrHasContinuationRoom
            ? start + (hdrTarget - start) * (1 - 0.5 * hdrRolloff) : 1
        return max(1, endpoint * hdrGain)
    }

    static let minimumRange = 1.0 / 2048

    var hdrHasContinuationRoom: Bool { peakPosition < 1 - 1e-12 }

    var hdrFallsBelowSDR: Bool {
        hdrEnabled && curve(hdr: true).fallsBelow(curve(hdr: false))
    }

    /// Hidden endpoint of the unscaled HDR continuation.
    mutating func setAutomaticHDRTarget() {
        let sdr = curve(hdr: false)
        let join = peakPosition
        let gain = sdr.value(at: join) + sdrSlope(at: join, curve: sdr) * (1 - join)
        hdrTarget = min(20, max(1, gain))
    }

    private func sdrSlope(at join: Double, curve sdr: ToneCurve) -> Double {
        // Use the actual sampled SDR segment's slope, including its left-hand
        // slope at white (the clipped segment to its right is not the tangent).
        let position = min(1, max(0, (join - black) / (white - black)))
        let index = min(sdr.values.count - 2, Int(position * Double(sdr.values.count - 1)))
        return (sdr.values[index + 1] - sdr.values[index])
            * Double(sdr.values.count - 1) / (white - black)
    }

    private func hdrCurve() -> ToneCurve {
        let sdr = curve(hdr: false)
        let join = peakPosition
        let start = sdr.value(at: join)
        let width = 1 - join
        let count = 2000
        let values = (0...count).map { index -> Double in
            let input = black + (1 - black) * Double(index) / Double(count)
            let base: Double
            if input <= join || width <= 1e-12 {
                base = sdr.value(at: input)
            } else {
                let t = (input - join) / width
                // The slope declines from its starting value to zero at full rolloff.
                base = start + (hdrTarget - start) * (t - 0.5 * hdrRolloff * t * t)
            }
            return base * hdrGain
        }
        return ToneCurve(values: values, black: black, white: 1)
    }

    func curve(hdr: Bool) -> ToneCurve {
        if hdr && hdrEnabled { return hdrCurve() }
        let upperInput = white
        let outputMax = 1.0
        let span = max(Self.minimumRange, upperInput - black)
        let count = 2000
        let effectiveConcentration = concentration
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

    /// Combined knots suffice: the difference is linear between adjacent knots.
    func fallsBelow(_ other: ToneCurve) -> Bool {
        for curve in [self, other] {
            for index in curve.values.indices {
                let input = curve.black + (curve.white - curve.black)
                    * Double(index) / Double(curve.values.count - 1)
                if value(at: input) + 0.000001 < other.value(at: input) { return true }
            }
        }
        return false
    }

    func value(at input: Double) -> Double {
        let normalized = (input - black) / max(ToneMapping.minimumRange, white - black)
        if normalized <= 0 { return 0 }
        if normalized >= 1 { return values.last! }
        let position = normalized * Double(values.count - 1)
        let index = min(values.count - 2, Int(position))
        return values[index] + (values[index + 1] - values[index]) * (position - Double(index))
    }
}
