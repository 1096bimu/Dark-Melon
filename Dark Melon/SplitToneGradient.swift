import CoreImage
import Foundation
import simd

nonisolated struct SplitToneNode: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var lightness: Double
    var hue = 0.0
    var strength = 0.0
}

nonisolated enum OKLabColor {
    private static let fromSRGB = Dictionary(uniqueKeysWithValues: ProcessingColorSpace.allCases.map {
        ($0, (ScopeProjection.matrix(.sRGB).inverse * ScopeProjection.matrix($0)).inverse)
    })
    static func linear(_ lab: SIMD3<Double>, space: ProcessingColorSpace) -> SIMD3<Double> {
        let l = lab.x+0.3963377774*lab.y+0.2158037573*lab.z
        let m = lab.x-0.1055613458*lab.y-0.0638541728*lab.z
        let s = lab.x-0.0894841775*lab.y-1.2914855480*lab.z
        let rgb = SIMD3(4.0767416621*l*l*l-3.3077115913*m*m*m+0.2309699292*s*s*s,
                        -1.2684380046*l*l*l+2.6097574011*m*m*m-0.3413193965*s*s*s,
                        -0.0041960863*l*l*l-0.7034186147*m*m*m+1.7076147010*s*s*s)
        return fromSRGB[space]! * rgb
    }
    static func maximumChroma(lightness: Double, hue: Double, ceiling: Double, space: ProcessingColorSpace) -> Double {
        guard lightness > 0, lightness < cbrt(ceiling) else { return 0 }
        let angle = hue * .pi/180
        var low = 0.0, high = 2*cbrt(ceiling)
        for _ in 0..<22 {
            let c = (low+high)/2
            let rgb = linear(SIMD3(lightness,c*cos(angle),c*sin(angle)),space:space)
            if rgb.min() >= -1e-9 && rgb.max() <= ceiling+1e-9 { low=c } else { high=c }
        }
        return low
    }
    static func tint(_ node: SplitToneNode, ceiling: Double, space: ProcessingColorSpace) -> SIMD2<Double> {
        let c = maximumChroma(lightness:node.lightness,hue:node.hue,ceiling:ceiling,space:space)*node.strength
        let angle = node.hue * .pi/180
        return SIMD2(c*cos(angle),c*sin(angle))
    }
    static func interpolate(_ lightness: Double, nodes: [(Double,SIMD2<Double>)]) -> SIMD2<Double> {
        guard let first=nodes.first else { return .zero }
        if lightness <= first.0 { return first.1 }
        for i in 1..<nodes.count where lightness <= nodes[i].0 {
            let a=nodes[i-1], b=nodes[i]
            let t=(lightness-a.0)/max(1e-9,b.0-a.0)
            return a.1+(b.1-a.1)*t
        }
        return nodes.last!.1
    }
}

nonisolated final class SplitToneGradient {
    private let kernel: CIKernel? = {
        let functions=String(ColorPixelKernel.source.prefix(upTo:ColorPixelKernel.source.range(of:"kernel vec4 colorAdjust")!.lowerBound))
        return CIKernel(source:functions + """
        kernel vec4 gradientTint(sampler image, sampler table, float ceiling, float domain,
            vec3 to0,vec3 to1,vec3 to2,vec3 from0,vec3 from1,vec3 from2) {
            vec4 p=unpremultiply(sample(image,samplerCoord(image)));
            vec3 lab=toOKLab(convertRGB(p.rgb,to0,to1,to2));
            vec2 tint=sample(table,vec2(clamp(lab.x/domain,0.0,1.0)*511.0+0.5,0.5)).xy;
            if (length(tint)<0.0000001) { return premultiply(p); }
            vec3 target=vec3(lab.x,lab.yz+tint);
            vec3 rgb=convertRGB(fromOKLab(target),from0,from1,from2);
            if (min(rgb.r,min(rgb.g,rgb.b))<0.0 || max(rgb.r,max(rgb.g,rgb.b))>ceiling) {
                float low=0.0; float high=1.0;
                for (int i=0;i<14;i++) {
                    float t=(low+high)*0.5;
                    vec3 candidate=convertRGB(fromOKLab(vec3(target.x,target.yz*t)),from0,from1,from2);
                    if (min(candidate.r,min(candidate.g,candidate.b))>=0.0 && max(candidate.r,max(candidate.g,candidate.b))<=ceiling) { low=t; } else { high=t; }
                }
                rgb=convertRGB(fromOKLab(vec3(target.x,target.yz*low)),from0,from1,from2);
            }
            return premultiply(vec4(rgb,p.a));
        }
        """)
    }()

    func apply(_ image: CIImage, settings: SplitToneSettings, space: ProcessingColorSpace, ceiling: Double, domainCeiling: Double) throws -> CIImage {
        guard let nodes=settings.nodes, nodes.contains(where:{$0.strength>0}) else { return image }
        let domain=cbrt(domainCeiling)
        let knots=nodes.sorted{$0.lightness<$1.lightness}.map{($0.lightness,OKLabColor.tint($0,ceiling:domainCeiling,space:space))}
        let pixels=(0..<512).flatMap { i -> [Float] in
            let tint=OKLabColor.interpolate(domain*Double(i)/511,nodes:knots)
            return [Float(tint.x),Float(tint.y),0,1]
        }
        let table=CIImage(bitmapData:pixels.withUnsafeBytes{Data($0)},bytesPerRow:512*16,size:CGSize(width:512,height:1),format:.RGBAf,colorSpace:nil)
        let to=ScopeProjection.matrix(.sRGB).inverse * ScopeProjection.matrix(space), from=to.inverse
        func row(_ m:simd_double3x3,_ i:Int)->CIVector { CIVector(x:m[0][i],y:m[1][i],z:m[2][i]) }
        guard let output=kernel?.apply(extent:image.extent,roiCallback:{index,rect in index==1 ? table.extent:rect},arguments:[image,CISampler(image:table,options:[kCISamplerFilterMode:kCISamplerFilterLinear,kCISamplerWrapMode:kCISamplerWrapClamp]),ceiling,domain,row(to,0),row(to,1),row(to,2),row(from,0),row(from,1),row(from,2)]) else { throw CocoaError(.coderInvalidValue) }
        return output
    }
}
