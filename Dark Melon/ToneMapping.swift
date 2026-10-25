import Foundation

nonisolated struct ToneMapping: Codable, Equatable, Sendable {
    var lutID: UUID? = nil
    var transform: TransformSettings? = nil
    var whiteBalance = WhiteBalance()
    var rawWhiteBalance: RAWWhiteBalance?
    var blackAndWhite = BlackAndWhiteSettings()
    var color = ColorAdjustments()
    var vertexWarp = OKLabVertexWarp.defaults
    var hls = [HLSAdjustment](repeating: HLSAdjustment(), count: 6)
    var clarity = 0.0
    var clarityRadius = 30.0
    var hdf = 0.0
    var hdfRadius = 100.0
    var grain = FilmGrainSettings()
    var halation = HalationSettings()
    var vignette = VignetteSettings()
    var offset = 0.0
    var white = 1.0
    var tonePosition = 0.040
    var toneUsesSourceLuminance = true
    var peakPosition: Double { tonePosition }
    var concentration = 0.4
    var channelContrast = [0.0, 0.0, 0.0]
    var hdrTarget = 4.0
    var hdrGain = 1.0
    var hdrRolloff = 0.0
    // Negative rolloff doubles the available upward curvature. At -100%, the
    // continuation's rise doubles, while its join and starting tangent stay fixed.
    private var hdrCurvature: Double { hdrRolloff < 0 ? 2 * hdrRolloff : hdrRolloff }
    var hdrEnabled: Bool { hdrGain > 0 }
    /// Rendering headroom and effect ceilings must cover the multiplied curve.
    var hdrMax: Double {
        guard hdrEnabled else { return 1 }
        if dyeContrastOffsets.contains(where: { $0 != 0 }) {
            return (0..<3).map { channelMapping($0).hdrMax }.max()!
        }
        let start = curve(hdr: false).value(at: peakPosition)
        let endpoint = hdrHasContinuationRoom
            ? start + (hdrTarget - start) * (1 - 0.5 * hdrCurvature) : 1
        return max(1, endpoint * hdrGain)
    }

    static func fresh(isRAW: Bool, sourceHeadroom: Double) -> ToneMapping {
        var result = ToneMapping()
        if !isRAW {
            result.concentration = 0
            // Non-RAW decoding divides by headroom to fit our input domain.
            // A linear curve and the inverse gain restore the decoded HDR pixels.
            let headroom = sourceHeadroom.isFinite ? max(1, sourceHeadroom) : 1
            result.hdrGain = headroom > 1 ? headroom : 0
        }
        result.setAutomaticHDRTarget()
        return result
    }

    /// Remove the common component. Scale all deltas together near the contrast
    /// limits so independent clipping cannot introduce a shared contrast offset.
    var dyeContrastOffsets: [Double] {
        let relative = channelContrast.map { $0 - channelContrast[0] }
        let mean = relative.reduce(0, +) / 3
        let deltas = relative.map { $0 - mean }
        var scale = 1.0
        for delta in deltas {
            if delta > 0 { scale = min(scale, (1 - concentration) / delta) }
            if delta < 0 { scale = min(scale, (-1 - concentration) / delta) }
        }
        return deltas.map { $0 * max(0, scale) }
    }

    /// Channel offsets share the same tone position and clipping point. Each
    /// HDR continuation follows its own SDR tangent, before common gain/rolloff.
    private func channelMapping(_ channel: Int) -> ToneMapping {
        var result = self
        result.channelContrast = [0, 0, 0]
        let offset = dyeContrastOffsets[channel]
        if offset != 0 {
            result.concentration = min(1, max(-1, concentration + offset))
            result.setAutomaticHDRTarget()
        }
        return result
    }

    func channelCurves(hdr: Bool) -> [ToneCurve] {
        guard dyeContrastOffsets.contains(where: { $0 != 0 }) else {
            return Array(repeating: curve(hdr: hdr), count: 3)
        }
        return (0..<3).map { channelMapping($0).curve(hdr: hdr) }
    }

    static let minimumRange = 1.0 / 2048

    var hdrHasContinuationRoom: Bool { peakPosition < 1 - 1e-12 }

    var hdrFallsBelowSDR: Bool {
        guard hdrEnabled else { return false }
        let sdr = channelCurves(hdr: false), hdr = channelCurves(hdr: true)
        return (0..<3).contains { hdr[$0].fallsBelow(sdr[$0]) }
    }

    /// Hidden endpoint of the unscaled HDR continuation.
    mutating func setAutomaticHDRTarget() {
        let sdr = curve(hdr: false)
        let join = peakPosition
        let gain = sdr.value(at: join) + sdrSlope(at: join, curve: sdr) * (1 - join)
        hdrTarget = min(20, max(1, gain))
        // Updating the target preserves the user’s HDR Gain, including an explicit Off.
    }

    func sdrSlope(at join: Double, curve sdr: ToneCurve) -> Double {
        // Use the actual sampled SDR segment's slope, including its left-hand
        // slope at white (the clipped segment to its right is not the tangent).
        let position = min(1, max(0, join / white))
        let index = min(sdr.values.count - 2, Int(position * Double(sdr.values.count - 1)))
        return (sdr.values[index + 1] - sdr.values[index])
            * Double(sdr.values.count - 1) / white
    }

    private func hdrCurve() -> ToneCurve {
        let sdr = curve(hdr: false)
        let join = peakPosition
        let start = sdr.value(at: join)
        let width = 1 - join
        let count = 2000
        let values = (0...count).map { index -> Double in
            let input = Double(index) / Double(count)
            let base: Double
            if input <= join || width <= 1e-12 {
                base = sdr.value(at: input)
            } else {
                let t = (input - join) / width
                // Positive curvature flattens; negative curvature increases the slope.
                base = start + (hdrTarget - start) * (t - 0.5 * hdrCurvature * t * t)
            }
            return base * hdrGain
        }
        return ToneCurve(values: values, black: 0, white: 1)
    }

    func curve(hdr: Bool) -> ToneCurve {
        if hdr && hdrEnabled { return hdrCurve() }
        let upperInput = white
        let outputMax = 1.0
        let span = max(Self.minimumRange, upperInput)
        let count = 2000
        let effectiveConcentration = concentration
        guard effectiveConcentration != 0 else {
            return ToneCurve(values: (0...count).map { Double($0) / Double(count) * outputMax },
                             black: 0, white: upperInput)
        }
        let sharedPeak = min(white, max(0, peakPosition))
        let peak = min(1, max(0, sharedPeak / span))
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
        return ToneCurve(values: values.map { $0 * scale }, black: 0, white: upperInput)
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
