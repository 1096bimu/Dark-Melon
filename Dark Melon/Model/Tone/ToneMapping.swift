import Foundation
import Synchronization

nonisolated struct ToneMapping: Codable, Equatable, Sendable {
    var doubleExposure: DoubleExposure? = nil
    var sourceMaximum: Double { doubleExposure == nil ? 1 : 2 }
    var lutID: UUID? = nil
    // Optional storage keeps old library presets and snapshots decodable.
    private var lutAmount: Double?
    var lutStrength: Double {
        get { lutAmount ?? 1 }
        set { lutAmount = newValue == 1 ? nil : newValue }
    }
    var dustSpots: [DustSpot]? = nil
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
    var badHDR = BadHDRSettings()
    var grain = FilmGrainSettings()
    var halation = HalationSettings()
    var vignette = VignetteSettings()
    /// Equivalent 8-bit SDR output code, independent of the tone curve.
    private var storedShadowFloorCode: Double?
    var shadowFloor: Double {
        get { storedShadowFloorCode ?? 0 }
        set { storedShadowFloorCode = newValue == 0 ? nil : newValue }
    }
    var white = 0.5
    var tonePosition = 0.040
    var toneUsesSourceLuminance = true
    var peakPosition: Double { tonePosition }
    var concentration = 0.2
    // A new key deliberately discards the former distribution weights and experimental curve settings.
    private var storedContrastDistribution: ToneContrastDistribution?
    var contrastDistribution: ToneContrastDistribution {
        get { storedContrastDistribution ?? ToneContrastDistribution() }
        set { storedContrastDistribution = newValue == ToneContrastDistribution() ? nil : newValue }
    }
    var channelContrast = [0.0, 0.0, 0.0]
    var dyeMixers = DyeMixers()
    private var storedDyePurity: [Double]?
    var dyePurity: [Double] {
        get { storedDyePurity ?? [1, 1, 1] }
        set { storedDyePurity = newValue == [1, 1, 1] ? nil : newValue }
    }
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
        let start = curve(hdr: false).value(at: peakPosition)
        let endpoint = hdrHasContinuationRoom
            ? start + (hdrTarget - start) * (1 - 0.5 * hdrCurvature) : 1
        return max(1, endpoint * hdrGain)
    }

    static func fresh(isRAW: Bool, sourceHeadroom: Double) -> ToneMapping {
        var result = ToneMapping()
        if !isRAW {
            result.white = 1
            result.concentration = 0
            // Non-RAW decoding divides by headroom to fit our input domain.
            // A linear curve and the inverse gain restore the decoded HDR pixels.
            let headroom = sourceHeadroom.isFinite ? max(1, sourceHeadroom) : 1
            result.hdrGain = headroom > 1 ? headroom : 0
        }
        result.setAutomaticHDRTarget()
        return result
    }

    /// Relative film-layer slopes. Independent of output contrast: equal RGB
    /// settings remain neutral, even at the main Contrast slider's limits.
    var dyeContrastOffsets: [Double] {
        let relative = channelContrast.map { $0 - channelContrast[0] }
        let mean = relative.reduce(0, +) / 3
        let deltas = relative.map { $0 - mean }
        let largest = deltas.map { abs($0) }.max() ?? 0
        let scale = largest > 0.8 ? 0.8 / largest : 1
        return deltas.map { $0 * scale }
    }

    func channelCurves(hdr: Bool) -> [ToneCurve] {
        Array(repeating: curve(hdr: hdr), count: 3)
    }

    static let minimumRange = 1.0 / 2048

    var hdrHasContinuationRoom: Bool { peakPosition < sourceMaximum - 1e-12 }

    var hdrFallsBelowSDR: Bool {
        guard hdrEnabled else { return false }
        let sdr = channelCurves(hdr: false), hdr = channelCurves(hdr: true)
        return (0..<3).contains { hdr[$0].fallsBelow(sdr[$0]) }
    }

    /// Hidden endpoint of the unscaled HDR continuation.
    mutating func setAutomaticHDRTarget() {
        let sdr = curve(hdr: false)
        let join = peakPosition
        let gain = sdr.value(at: join) + sdrSlope(at: join, curve: sdr) * (sourceMaximum - join)
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
        let width = sourceMaximum - join
        let count = 2000
        let values = (0...count).map { index -> Double in
            let input = Double(index) / Double(count) * sourceMaximum
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
        return ToneCurve(values: values, black: 0, white: sourceMaximum)
    }

    // Small shared cache also serves histogram/target calculations. Compute outside
    // the lock: an HDR curve recursively requests its SDR curve.
    private struct CurveKey: Hashable {
        var white: Double
        var tone: Double
        var contrast: Double
        var distribution: ToneContrastDistribution
        var hdr: Bool
        var target: Double
        var gain: Double
        var rolloff: Double
        var sourceMaximum: Double
    }
    private static let curveCache = Mutex<[CurveKey: ToneCurve]>([:])

    func curve(hdr: Bool) -> ToneCurve {
        let isHDR = hdr && hdrEnabled
        let key = CurveKey(white: white, tone: peakPosition, contrast: concentration,
            distribution: contrastDistribution, hdr: isHDR,
            target: isHDR ? hdrTarget : 0, gain: isHDR ? hdrGain : 0,
            rolloff: isHDR ? hdrRolloff : 0, sourceMaximum: sourceMaximum)
        if let cached = Self.curveCache.withLock({ $0[key] }) { return cached }
        let result = uncachedCurve(hdr: isHDR)
        Self.curveCache.withLock {
            if $0.count >= 16 { $0.removeAll(keepingCapacity: true) }
            $0[key] = result
        }
        return result
    }

    // The LUT viewer's ramp uses encoded sRGB on both axes, with its linear
    // input scaled to the white point. This samples only the SDR tone function.
    private static let rampInputs: [Double] = (0...256).map {
        let x = Double($0) / 256
        return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    }

    func neutralSDRRamp() -> [Double] {
        let curve = curve(hdr: false)
        return Self.rampInputs.map { input in
            let output = curve.value(at: input * white).clamped(to: 0...1)
            return output <= 0.0031308 ? output * 12.92 : 1.055 * pow(output, 1 / 2.4) - 0.055
        }
    }

    private func uncachedCurve(hdr: Bool) -> ToneCurve {
        if hdr && hdrEnabled { return hdrCurve() }
        let values = contrastDistribution.values(
            peak: peakPosition / max(Self.minimumRange, white), contrast: concentration)
        return ToneCurve(values: values, black: 0, white: white)
    }
}

nonisolated struct ToneCurve: Equatable, Sendable {
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
