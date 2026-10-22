import Foundation
import simd

/// Fixed reference geometry, never recomputed from edited colors.
nonisolated enum ColorSliceGeometry {
    struct Slice {
        let hue: Double
        let apex: SIMD3<Double>
        let lower: Double
        let upper: Double
    }
    static let referenceChroma = 0.1
    static let cache: [ProcessingColorSpace: [Slice]] = Dictionary(uniqueKeysWithValues:
        ProcessingColorSpace.allCases.map { space in
            (space, OKLabVertexWarp.vertexHues[space]!.map { slice(hue: $0, space: space) })
        })
    static func slice(hue: Double, space: ProcessingColorSpace) -> Slice {
        let direction = SIMD2(cos(hue),sin(hue))
        // Homogeneity: every valid ray can be scaled until one RGB channel reaches 1.
        var best = SIMD3<Double>(1,0,0), bestC = 0.0
        for i in 1...2048 {
            let c=Double(i)/2048
            let rgb=OKLabColor.linear(SIMD3(1,c*direction.x,c*direction.y),space:space)
            if rgb.min() < 0 { continue }
            let scale=cbrt(1/max(1e-12,rgb.max()))
            if c*scale>bestC { bestC=c*scale;best=SIMD3(scale,c*scale*direction.x,c*scale*direction.y) }
        }
        func inside(_ l: Double) -> Bool {
            let rgb=OKLabColor.linear(SIMD3(l,referenceChroma*direction.x,referenceChroma*direction.y),space:space)
            return rgb.min() >= 0 && rgb.max() <= 1
        }
        var first: Int?, last: Int?
        for i in 0...1024 where inside(Double(i)/1024) {
            if first == nil { first=i }; last=i
        }
        guard let first, let last else { return Slice(hue:hue,apex:best,lower:best.x,upper:best.x) }
        func edge(_ a: Double,_ b: Double, lower: Bool) -> Double {
            var lo=a,hi=b
            for _ in 0..<20 {
                let mid=(lo+hi)/2
                if inside(mid)==lower { hi=mid } else { lo=mid }
            }
            return (lo+hi)/2
        }
        return Slice(hue:hue,apex:best,
            lower:edge(Double(max(0,first-1))/1024,Double(first)/1024,lower:true),
            upper:edge(Double(last)/1024,Double(min(1024,last+1))/1024,lower:false))
    }
    static func bend(lightness: Double, chroma: Double, slice: Slice, lower: Double, upper: Double) -> Double {
        let endpoint = lightness < slice.apex.x ? slice.lower : slice.upper
        let span = max(1e-6,abs(endpoint-slice.apex.x))
        let t = min(1,abs(lightness-slice.apex.x)/span)
        let c = min(1,max(0,chroma/referenceChroma))
        return (lightness < slice.apex.x ? lower : upper)*t*t*(3-2*t)*c*c*(3-2*c)
    }
}
