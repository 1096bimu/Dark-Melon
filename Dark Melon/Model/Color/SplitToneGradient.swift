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
    static func table(settings: SplitToneSettings, space: ProcessingColorSpace, ceiling: Double) -> CIImage {
        let domain=cbrt(ceiling)
        let knots=(settings.nodes ?? []).sorted{$0.lightness<$1.lightness}.map{($0.lightness,OKLabColor.tint($0,ceiling:ceiling,space:space))}
        let pixels=(0..<512).flatMap { i -> [Float] in
            let tint=OKLabColor.interpolate(domain*Double(i)/511,nodes:knots)
            return [Float(tint.x),Float(tint.y),0,1]
        }
        return CIImage(bitmapData:pixels.withUnsafeBytes{Data($0)},bytesPerRow:512*16,size:CGSize(width:512,height:1),format:.RGBAf,colorSpace:nil)
    }
    private let pipeline=OKLabColorPipeline()
    func apply(_ image: CIImage, settings: SplitToneSettings, space: ProcessingColorSpace, ceiling: Double, domainCeiling: Double) throws -> CIImage {
        var color=ColorAdjustments();color.splitTone=settings
        return try pipeline.apply(image,color:color,vertices:Array(repeating:OKLabVertexAdjustment(),count:6),space:space,ceiling:ceiling,domainCeiling:domainCeiling)
    }
}
