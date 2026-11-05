import Foundation

/// Both widths at 50% and unlifted endpoints reproduce the original beta curve.
nonisolated struct ToneContrastDistribution: Codable, Equatable, Hashable, Sendable {
    var black = 0.0
    var shadowWidth = 0.5
    var highlightWidth = 0.5
    var white = 0.0

    func values(peak: Double, contrast: Double, count: Int = 2000) -> [Double] {
        let peak = peak.clamped(to: 0...1)
        let base = ToneBetaProfile(peak: peak, contrast: contrast, shadowWidth: shadowWidth, highlightWidth: highlightWidth, count: count)
        var values = base.values
        guard black != 0 || white != 0 else { return values }

        // Positive endpoint lobes have analytic areas. Restrict their areas
        // relative to the beta endpoint slopes so all mixture weights stay
        // nonnegative, including broad negative-contrast profiles.
        let endpointScale = max(1, base.blackSlope, base.whiteSlope)
        let blackArea = max(0.002, 0.25 * peak) / endpointScale
        let whiteArea = max(0.002, 0.25 * (1 - peak)) / endpointScale
        let targetBlack = base.blackSlope + black, targetWhite = base.whiteSlope + white
        let scale = (1 - targetBlack * blackArea - targetWhite * whiteArea)
                  / (1 - base.blackSlope * blackArea - base.whiteSlope * whiteArea)
        let blackWeight = targetBlack - scale * base.blackSlope
        let whiteWeight = targetWhite - scale * base.whiteSlope
        for i in 1..<count {
            let x = Double(i) / Double(count)
            let left = -blackArea * expm1(log1p(-x) / blackArea)
            let right = whiteArea * pow(x, 1 / whiteArea)
            values[i] = scale * values[i] + blackWeight * left + whiteWeight * right
        }
        values[count] = 1
        return values
    }
}

extension ToneContrastDistribution {
    private enum CodingKeys: String, CodingKey { case black, shadowWidth, highlightWidth, white }

    init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        black = try container.decodeIfPresent(Double.self, forKey: .black) ?? black
        shadowWidth = try container.decodeIfPresent(Double.self, forKey: .shadowWidth) ?? shadowWidth
        highlightWidth = try container.decodeIfPresent(Double.self, forKey: .highlightWidth) ?? highlightWidth
        white = try container.decodeIfPresent(Double.self, forKey: .white) ?? white
    }
}

/// A generalized beta slope profile. Shape acts on the negative log density;
/// each half is fitted to retain its original profile area. Its peak remains
/// one before normalization, so Contrast alone controls the slope at Tone.
nonisolated struct ToneBetaProfile {
    let values: [Double]
    let blackSlope: Double
    let whiteSlope: Double
    let centerSlope: Double

    init(peak: Double, contrast: Double, shadowWidth: Double, highlightWidth: Double, count: Int) {
        if contrast == 0 {
            values = (0...count).map { Double($0) / Double(count) }
            blackSlope = 1; whiteSlope = 1; centerSlope = 1
            return
        }
        let negative = contrast < 0
        let k = negative ? 2 : expm1(log(257) * contrast)
        let a = k * peak, b = k * (1 - peak)
        let peakLog = (a == 0 ? 0 : a * log(peak))
                    + (b == 0 ? 0 : b * log1p(-peak))
        func logDensity(_ x: Double) -> Double {
            // Zero coefficients also cover Tone exactly at either endpoint.
            (a == 0 ? 0 : a * log(x)) + (b == 0 ? 0 : b * log1p(-x)) - peakLog
        }
        let sampleCount = 2 * count
        let divisor = Double(sampleCount)
        var profiles = [Double](repeating: 0, count: sampleCount)
        let needsFitting = shadowWidth != 0.5 || highlightWidth != 0.5
        var logDistances = needsFitting ? [Double](repeating: 0, count: sampleCount) : []
        for i in profiles.indices {
            let x = (Double(i) + 0.5) / divisor
            let logValue = logDensity(x)
            profiles[i] = exp(logValue)
            if needsFitting { logDistances[i] = max(0, -logValue) }
        }
        func refit(width: Double, indices: Range<Int>) {
            guard width != 0.5, !indices.isEmpty else { return }
            let shape = exp2((width < 0.5 ? 2 : 4) * (width - 0.5)) // 0.5 ... 1 ... 4
            let targetArea = indices.reduce(0.0) { $0 + profiles[$1] } / Double(indices.count)
            let distances = indices.map { pow(logDistances[$0], shape) }
            let coefficient = Self.fittedScale(distances, targetArea: targetArea)
            for (offset, index) in indices.enumerated() {
                profiles[index] = exp(-coefficient * distances[offset])
            }
        }
        // Fit each half to its original mass independently. Changing one side
        // therefore preserves both the output and tangent at Tone, and leaves
        // the other side unchanged (apart from the table's crossing interval).
        let split = min(sampleCount, max(0, Int(ceil(peak * divisor - 0.5))))
        refit(width: 1 - shadowWidth, indices: 0..<split)
        refit(width: highlightWidth, indices: split..<sampleCount)

        // Preserve the original quarter/three-quarter integration and sample
        // count. Neutral widths bypass shape fitting and retain the old curve.
        var samples = [Double](repeating: 0, count: count + 1)
        for i in 0..<count {
            let first = negative ? max(0, 1 + contrast * profiles[2*i]) : profiles[2*i]
            let second = negative ? max(0, 1 + contrast * profiles[2*i+1]) : profiles[2*i+1]
            samples[i+1] = samples[i] + (first + second) / divisor
        }
        let area = samples[count]
        let normalization = 1 / area
        for i in 1...count { samples[i] *= normalization }
        samples[count] = 1
        values = samples
        centerSlope = (negative ? 1 + contrast : 1) / area
        func endpointSlope(_ x: Double) -> Double {
            let profile = exp(logDensity(x))
            return (negative ? max(0, 1 + contrast * profile) : profile) / area
        }
        blackSlope = endpointSlope(0)
        whiteSlope = endpointSlope(1)
    }

    private static func fittedScale(_ distances: [Double], targetArea: Double) -> Double {
        let divisor = Double(distances.count)
        func integral(_ scale: Double) -> (area: Double, derivative: Double) {
            var area = 0.0, derivative = 0.0
            for distance in distances {
                let value = exp(-scale * distance)
                area += value
                derivative -= distance * value
            }
            return (area / divisor, derivative / divisor)
        }
        var low = 0.0, high = 1.0
        while integral(high).area > targetArea { high *= 2 }
        var scale = (low + high) / 2
        // Safeguarded Newton fitting usually takes a handful of iterations;
        // bisection keeps it stable at the extreme Tone/Contrast settings.
        for _ in 0..<40 {
            let result = integral(scale)
            let error = result.area - targetArea
            if abs(error) <= 1e-12 * targetArea { break }
            if error > 0 { low = scale } else { high = scale }
            let next = result.derivative < 0 ? scale - error / result.derivative : .nan
            scale = next > low && next < high ? next : (low + high) / 2
        }
        return scale
    }
}
