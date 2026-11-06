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
