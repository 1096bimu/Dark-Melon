import Foundation

nonisolated struct ColorAdjustments: Codable, Equatable, Sendable {
    var monochrome = false
    var saturationStart = 1.0
    var saturationEnd = 1.0
    var saturationMid = 1.0
    var saturationHDR = 1.0
    var luminanceSaturationStart = 1.0
    var luminanceSaturationEnd = 1.0
    var luminanceSaturationMid = 1.0
    var luminanceSaturationHDR = 1.0
    var isLuminanceSaturationIdentity: Bool { luminanceSaturationStart == 1 && luminanceSaturationEnd == 1 && luminanceSaturationMid == 1 && luminanceSaturationHDR == 1 }
    var splitTone = SplitToneSettings()
    var isIdentity: Bool { !monochrome && saturationStart == 1 && saturationEnd == 1 && saturationMid == 1 && saturationHDR == 1 && isLuminanceSaturationIdentity && splitTone.isIdentity }
    init() {}
    private enum CodingKeys: String, CodingKey {
        case monochrome, saturationStart, saturationEnd, saturationMid, saturationHDR, luminanceSaturationStart, luminanceSaturationEnd, luminanceSaturationMid, luminanceSaturationHDR, splitTone
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        monochrome = try values.decodeIfPresent(Bool.self, forKey: .monochrome) ?? false
        saturationStart = try values.decodeIfPresent(Double.self, forKey: .saturationStart) ?? 1
        saturationEnd = try values.decodeIfPresent(Double.self, forKey: .saturationEnd) ?? 1
        saturationMid = try values.decodeIfPresent(Double.self, forKey: .saturationMid) ?? 1
        saturationHDR = try values.decodeIfPresent(Double.self, forKey: .saturationHDR) ?? 1
        luminanceSaturationStart = try values.decodeIfPresent(Double.self, forKey: .luminanceSaturationStart) ?? 1
        luminanceSaturationEnd = try values.decodeIfPresent(Double.self, forKey: .luminanceSaturationEnd) ?? 1
        luminanceSaturationMid = try values.decodeIfPresent(Double.self, forKey: .luminanceSaturationMid) ?? 1
        luminanceSaturationHDR = try values.decodeIfPresent(Double.self, forKey: .luminanceSaturationHDR) ?? 1
        splitTone = try values.decodeIfPresent(SplitToneSettings.self, forKey: .splitTone) ?? SplitToneSettings()
    }

}

nonisolated enum BoundedQuadraticCurve {
    static let coefficientLimits = -8.0...8.0

    static func coefficientRange(
        start: Double,
        end: Double,
        outputRange: ClosedRange<Double>,
        curvatureScale: Double
    ) -> ClosedRange<Double> {
        precondition(curvatureScale > 0)

        let start = start.clamped(to: outputRange)
        let end = end.clamped(to: outputRange)
        let upperDistanceAtStart = outputRange.upperBound - start
        let upperDistanceAtEnd = outputRange.upperBound - end
        let lowerDistanceAtStart = start - outputRange.lowerBound
        let lowerDistanceAtEnd = end - outputRange.lowerBound

        let upperCoefficient = pow(
            sqrt(upperDistanceAtStart) + sqrt(upperDistanceAtEnd),
            2
        ) / curvatureScale
        let lowerCoefficient = -pow(
            sqrt(lowerDistanceAtStart) + sqrt(lowerDistanceAtEnd),
            2
        ) / curvatureScale

        let lowerBound = max(coefficientLimits.lowerBound, lowerCoefficient)
        let upperBound = min(coefficientLimits.upperBound, upperCoefficient)
        return lowerBound...upperBound
    }

    static func value(
        at x: Double,
        start: Double,
        end: Double,
        coefficient: Double,
        outputRange: ClosedRange<Double>,
        curvatureScale: Double
    ) -> Double {
        let x = x.clamped(to: 0...1)
        let allowedCoefficients = coefficientRange(
            start: start,
            end: end,
            outputRange: outputRange,
            curvatureScale: curvatureScale
        )
        let coefficient = coefficient.clamped(to: allowedCoefficients)
        let linear = start + (end - start) * x
        return linear + coefficient * x * (1 - x) * curvatureScale
    }
}

nonisolated struct SplitToneSettings: Codable, Equatable, Sendable {
    var nodes: [SplitToneNode]? = []
    static let maximumAmount = 2.0
    var shadowHue: Double = 220
    var highlightHue: Double = 40
    // nil follows the straight chord between the two hues.
    var midpointRadius: Double? = nil
    var shadowAmount: Double = 0
    var highlightAmount: Double = 0
    var amountCurveA: Double = 0

    var isIdentity: Bool {
        if let nodes { return nodes.allSatisfy { $0.strength == 0 } }
        return shadowAmount == 0 && highlightAmount == 0 && amountCurveA == 0
    }

    private func endpoint(_ hue: Double) -> SIMD2<Double> {
        let radians = hue * .pi / 180
        return SIMD2(cos(radians), sin(radians))
    }

    var chordMidpoint: SIMD2<Double> {
        (endpoint(shadowHue) + endpoint(highlightHue)) * 0.5
    }

    var hueNormal: SIMD2<Double> {
        let chord = chordMidpoint
        let length = hypot(chord.x, chord.y)
        if length > 0.000_001 { return chord / length }
        let start = endpoint(shadowHue)
        return SIMD2(-start.y, start.x)
    }

    func huePoint(at tone: Double) -> SIMD2<Double> {
        let start = endpoint(shadowHue)
        let end = endpoint(highlightHue)
        let normal = hueNormal
        let naturalRadius = hypot(chordMidpoint.x, chordMidpoint.y)
        let radius = (midpointRadius ?? naturalRadius).clamped(to: 0...1)
        let midpoint = normal * radius
        let t = tone.clamped(to: 0...1)
        let chordPoint = t <= 0.5
            ? start + (midpoint - start) * (t * 2)
            : midpoint + (end - midpoint) * ((t - 0.5) * 2)
        guard radius > naturalRadius + 0.000_001,
              naturalRadius < 1 - 0.000_001 else {
            return chordPoint
        }
        // Outward deflection approaches the short arc on the rim. Inward
        // deflection stops at neutral, so the path never takes the long arc.
        let rimWeight = (radius - naturalRadius) / (1 - naturalRadius)
        let localT = t <= 0.5 ? t * 2 : (t - 0.5) * 2
        let rimEnd = t <= 0.5 ? normal : end
        let rimStart = t <= 0.5 ? start : normal
        let angleA = atan2(rimStart.y, rimStart.x)
        let angleB = atan2(rimEnd.y, rimEnd.x)
        let delta = atan2(sin(angleB - angleA), cos(angleB - angleA))
        let angle = angleA + delta * localT
        let rimPoint = SIMD2(cos(angle), sin(angle))
        return chordPoint * (1 - rimWeight) + rimPoint * rimWeight
    }

}

nonisolated struct HLSAdjustment: Codable, Equatable, Sendable {
    var shadowHue = 0.0
    var midtoneHue = 0.0
    var highlightHue = 0.0
    var saturation = 1.0
    var lightness = 0.0
    var isIdentity: Bool { self == HLSAdjustment() }
}

