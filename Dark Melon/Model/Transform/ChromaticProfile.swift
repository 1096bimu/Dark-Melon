import Foundation

/// A ray from the optical center in native source-pixel coordinates.
nonisolated struct RadialSampleLine: Equatable, Sendable {
    let size: CGSize
    let direction: CGPoint
    let lower: Double
    let upper: Double
    var length: Double { upper-lower }
    func point(at radius: Double) -> CGPoint {
        CGPoint(x: 0.5+direction.x*radius/size.width, y: 0.5+direction.y*radius/size.height)
    }
    static func constrained(from start: CGPoint, to end: CGPoint, size: CGSize) -> Self? {
        guard size.width > 0, size.height > 0,
              [start.x,start.y,end.x,end.y,size.width,size.height].allSatisfy(\.isFinite),
              (0...1).contains(start.x), (0...1).contains(start.y) else { return nil }
        let x=(start.x-0.5)*size.width, y=(start.y-0.5)*size.height
        let r=hypot(x,y)
        guard r > 1e-6 else { return nil }
        let direction=CGPoint(x:x/r,y:y/r)
        let maximum=min(abs(direction.x)>1e-12 ? size.width/2/abs(direction.x):.infinity,
                        abs(direction.y)>1e-12 ? size.height/2/abs(direction.y):.infinity)
        let projected=((end.x-0.5)*size.width*direction.x+(end.y-0.5)*size.height*direction.y).clamped(to:0...maximum)
        guard abs(r-projected) >= 2 else { return nil }
        return Self(size:size,direction:direction,lower:min(r,projected),upper:max(r,projected))
    }
}

/// Only a narrow RGB strip is retained. Candidate scales resample these traces,
/// so inspecting an edge never requires another full-image bake.
nonisolated struct ChromaticProfile: Sendable {
    let line: RadialSampleLine
    let sampleLower: Double
    let sampleUpper: Double
    let baseline: ChromaticAberration
    let channels: [[Double]]

    /// Align each normalized transition at its 50% height. Gradients only
    /// validate the match, so different shoulders cannot pull the midpoint away.
    /// The bounded search uses only the cached strip and leaves weak matches alone.
    func automaticallyAligned(from initial: ChromaticAberration) -> ChromaticAberration {
        let referenceValues = trace(initial, channel: 1)
        guard let reference = Self.edgeGradient(referenceValues) else { return initial }
        let peak = reference.indices.max { abs(reference[$0]) < abs(reference[$1]) }! + 2
        guard let midpoint = Self.edgeMidpoint(referenceValues, near: Double(peak)) else { return initial }
        let referenceEnergy = reference.reduce(0) { $0 + $1*$1 }
        var result = initial
        for channel in [0, 2] {
            func score(_ value: Double) -> Double {
                var settings = initial
                if channel == 0 { settings.red = value } else { settings.blue = value }
                let values = trace(settings, channel: channel)
                guard let edge = Self.edgeGradient(values) else { return -.infinity }
                var product = 0.0, energy = 0.0
                for (a, b) in zip(reference, edge) { product += a*b; energy += b*b }
                // Opposite-polarity colored edges still share a geometric edge.
                guard abs(product) / sqrt(referenceEnergy*energy) >= 0.8,
                      let center = Self.edgeMidpoint(values, near: midpoint) else { return -.infinity }
                return -abs(center-midpoint)
            }
            let original = channel == 0 ? initial.red : initial.blue
            let range = -0.1...0.1
            var best = original.clamped(to: range), bestScore = score(original.clamped(to: range))
            func consider(_ value: Double) {
                let value = value.clamped(to: range)
                let candidate = score(value)
                if candidate > bestScore + 1e-10 { best = value; bestScore = candidate }
            }
            // Keep automatic candidates within ±0.1%, including refinements.
            // The manual controls retain their wider adjustment range.
            let coarseStep = (range.upperBound-range.lowerBound)/100
            for i in 0...100 { consider(range.lowerBound + Double(i)*coarseStep) }
            var step = coarseStep
            for _ in 0..<3 {
                let center = best
                for i in -10...10 { consider(center + Double(i)*step/10) }
                step /= 10
            }
            guard bestScore.isFinite else { continue }
            if channel == 0 { result.red = best } else { result.blue = best }
        }
        return result
    }

    private static func edgeMidpoint(_ values: [Double], near anchor: Double) -> Double? {
        let half = (values.min()! + values.max()!) / 2
        var nearest: Double?
        for i in 0..<(values.count-1) {
            let a = values[i], b = values[i+1]
            guard a != b, (a <= half && b >= half) || (a >= half && b <= half) else { continue }
            let crossing = Double(i) + (half-a)/(b-a)
            if nearest == nil || abs(crossing-anchor) < abs(nearest!-anchor) { nearest = crossing }
        }
        return nearest
    }

    private static func edgeGradient(_ values: [Double]) -> [Double]? {
        guard values.count >= 9, values.allSatisfy(\.isFinite),
              let low = values.min(), let high = values.max(),
              high-low > max(1e-6, max(abs(low),abs(high))*0.005) else { return nil }
        // A short derivative window suppresses sample noise without moving the edge.
        let gradient = (2..<(values.count-2)).map { values[$0+2]-values[$0-2] }
        let energy = gradient.reduce(0) { $0+$1*$1 }
        let peak = gradient.map { abs($0) }.max() ?? 0
        // Flat fields and smooth ramps have no localized edge to align.
        guard energy > 1e-20, peak > 1.5*sqrt(energy/Double(gradient.count)) else { return nil }
        return gradient
    }

    func trace(_ settings: ChromaticAberration, channel: Int, count: Int = 512) -> [Double] {
        let values=channels[channel]
        guard !values.isEmpty, count > 1, sampleUpper > sampleLower else { return [] }
        let base = channel == 0 ? baseline.red : channel == 2 ? baseline.blue : 0
        let candidate = channel == 0 ? settings.red : channel == 2 ? settings.blue : 0
        let scale=(1+base/100)/(1+candidate/100)
        return (0..<count).map { i in
            let radius=(line.lower+line.length*Double(i)/Double(count-1))*scale
            let position=((radius-sampleLower)/(sampleUpper-sampleLower)*Double(values.count-1)).clamped(to:0...Double(values.count-1))
            let low=Int(position), high=min(values.count-1,low+1), fraction=position-Double(low)
            return values[low]*(1-fraction)+values[high]*fraction
        }
    }
}
