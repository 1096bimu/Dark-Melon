import CoreImage
import Foundation
import simd

nonisolated struct OKLabVertexAdjustment: Codable, Equatable, Sendable {
    var chroma = 1.0
    var lightness = 0.0
    var rotation = 0.0
    init(chroma: Double = 1, lightness: Double = 0, rotation: Double = 0) {
        self.chroma=chroma; self.lightness=lightness; self.rotation=rotation
    }
    private enum CodingKeys: String, CodingKey { case chroma, lightness, rotation }
    init(from decoder: Decoder) throws {
        let values=try decoder.container(keyedBy:CodingKeys.self)
        chroma=try values.decodeIfPresent(Double.self,forKey:.chroma) ?? 1
        lightness=try values.decodeIfPresent(Double.self,forKey:.lightness) ?? 0
        rotation=try values.decodeIfPresent(Double.self,forKey:.rotation) ?? 0
    }
    var isIdentity: Bool { chroma == 1 && lightness == 0 && rotation == 0 }
}

/// Compact hue-wedge deformation in OKLab. Neighboring hue faces bound influence.
nonisolated final class OKLabVertexWarp {
    static let vertices: [SIMD3<Double>] = [SIMD3(1,0,0),SIMD3(1,1,0),SIMD3(0,1,0),SIMD3(0,1,1),SIMD3(0,0,1),SIMD3(1,0,1)]
    static func lab(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        let l=cbrt(simd_dot(rgb,SIMD3(0.4122214708,0.5363325363,0.0514459929)))
        let m=cbrt(simd_dot(rgb,SIMD3(0.2119034982,0.6806995451,0.1073969566)))
        let s=cbrt(simd_dot(rgb,SIMD3(0.0883024619,0.2817188376,0.6299787005)))
        return SIMD3(0.2104542553*l+0.793617785*m-0.0040720468*s,
                     1.9779984951*l-2.428592205*m+0.4505937099*s,
                     0.0259040371*l+0.7827717662*m-0.808675766*s)
    }
    /// Signed fraction of the half-gap to the previous/next color. Adjacent
    /// controls at opposing extremes meet at a shared angular midpoint.
    static func rotationAngle(index: Int, amount: Double, space: ProcessingColorSpace) -> Double {
        let hues = vertexHues[space]!
        let previous = index == 0 ? hues[5] - 2 * .pi : hues[index-1]
        let next = index == 5 ? hues[0] + 2 * .pi : hues[index+1]
        let halfGap = amount < 0 ? (hues[index]-previous)/2 : (next-hues[index])/2
        return amount.clamped(to: -1...1) * halfGap
    }
    static let vertexHues: [ProcessingColorSpace: [Double]] = Dictionary(uniqueKeysWithValues:
        ProcessingColorSpace.allCases.map { space in
            let matrix=ScopeProjection.matrix(.sRGB).inverse * ScopeProjection.matrix(space)
            var previous = -Double.infinity
            let hues=vertices.map { vertex -> Double in
                let value=lab(matrix * vertex)
                var angle=atan2(value.z,value.y)
                while angle < previous { angle += 2 * .pi }
                previous=angle
                return angle
            }
            return (space,hues)
        })

    struct Field {
        let centers: [SIMD3<Double>]
        let hues: [Double]
        // Chroma multiplier, lightness offset, rotation in radians.
        let adjustments: [SIMD3<Double>]

        func mapped(_ p: SIMD3<Double>) -> SIMD3<Double> {
            let c=hypot(p.y,p.z)
            guard c>1e-10 else { return p }
            var h=atan2(p.z,p.y)
            if h<hues[0] { h += 2 * .pi }
            var multiplier=0.0, angle=0.0, offset=0.0
            for i in 0..<6 {
                let j=(i+1)%6, end=j==0 ? hues[0]+2 * .pi:hues[j]
                if h>=hues[i] && h<=end {
                    let t=(h-hues[i])/(end-hues[i]), w=t*t*(3-2*t)
                    for (index,weight) in [(i,1-w),(j,w)] {
                        let v=adjustments[index]
                        multiplier += weight*v.x; angle += weight*v.z
                        let r=min(1,c/hypot(centers[index].y,centers[index].z))
                        offset += weight*v.y*r*r*(3-2*r)
                    }
                    break
                }
            }
            return SIMD3(p.x+offset,c*multiplier*cos(h+angle),c*multiplier*sin(h+angle))
        }
    }

    static func field(controls: [OKLabVertexAdjustment], space: ProcessingColorSpace) -> Field {
        precondition(controls.count==6)
        let to=ScopeProjection.matrix(.sRGB).inverse * ScopeProjection.matrix(space)
        return Field(centers:vertices.map { lab(to * $0) } + [.zero,SIMD3(1,0,0)],
            hues:vertexHues[space]!, adjustments:controls.enumerated().map { i,c in
                SIMD3(c.chroma,c.lightness,rotationAngle(index:i,amount:c.rotation,space:space))
            })
    }

    // Standalone entry point used by focused checks; production combines all Color stages.
    private let pipeline=OKLabColorPipeline()
    func apply(_ image:CIImage,controls:[OKLabVertexAdjustment],space:ProcessingColorSpace,ceiling:Double) throws -> CIImage {
        try pipeline.apply(image,color:ColorAdjustments(),vertices:controls,space:space,ceiling:ceiling,domainCeiling:ceiling)
    }
}
