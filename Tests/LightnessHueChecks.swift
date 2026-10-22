import Foundation
import CoreImage
import simd
@testable import Dark_Melon

@main struct LightnessHueChecks {
    static func main() throws {
        for space in ProcessingColorSpace.allCases {
            let slices=ColorSliceGeometry.cache[space]!
            var controls=OKLabVertexWarp.defaults
            controls[1].darkerHue = -0.12
            controls[1].lighterHue = 0.18
            let field=OKLabVertexWarp.field(controls:controls,space:space)
            let s=slices[1]
            assert(s.lower<s.apex.x && s.apex.x<s.upper)
            assert(abs(ColorSliceGeometry.bend(lightness:s.lower,chroma:0.1,slice:s,lower:-0.12,upper:0.18)+0.12)<1e-9)
            assert(abs(ColorSliceGeometry.bend(lightness:s.upper,chroma:0.1,slice:s,lower:-0.12,upper:0.18)-0.18)<1e-9)
            assert(ColorSliceGeometry.bend(lightness:s.apex.x,chroma:0.3,slice:s,lower:-0.12,upper:0.18)==0)
            assert(field.mapped(SIMD3(0.5,0,0))==SIMD3(0.5,0,0))
            for slice in slices {
                for L in [slice.lower,slice.upper] {
                    let rgb=OKLabColor.linear(SIMD3(L,0.1*cos(slice.hue),0.1*sin(slice.hue)),space:space)
                    assert(rgb.min() > -0.00001 && rgb.max()<1.00001)
                }
            }
            let recipe=DevelopmentRecipe(colorSpace:space,mapping: {
                var m=ToneMapping();m.vertexWarp=controls;return m
            }())
            let decoded=try DevelopmentRecipe.decode(recipe.encoded())
            assert(decoded.mapping.vertexWarp==controls)
            let pipeline=OKLabColorPipeline()
            let context=CIContext(options:[.workingColorSpace:space.linear,.workingFormat:CIFormat.RGBAf])
            for ceiling in [1.0,8.0] {
                let scale=cbrt(ceiling)
                for L in [s.lower,s.apex.x,s.upper] {
                    let p=SIMD3(L,0.03*cos(s.hue),0.03*sin(s.hue))
                    let rgb=OKLabColor.linear(p*scale,space:space)
                    let ci=CIImage(color:CIColor(red:rgb.x,green:rgb.y,blue:rgb.z,colorSpace:space.linear)!)
                        .cropped(to:CGRect(x:0,y:0,width:1,height:1))
                    let output=try pipeline.apply(ci,color:ColorAdjustments(),vertices:controls,
                        space:space,ceiling:ceiling,domainCeiling:ceiling)
                    var values=[Float](repeating:0,count:4)
                    context.render(output,toBitmap:&values,rowBytes:16,bounds:ci.extent,format:.RGBAf,colorSpace:space.linear)
                    let expected=OKLabColor.linear(field.mapped(p)*scale,space:space)
                    let actual=SIMD3(Double(values[0]),Double(values[1]),Double(values[2]))
                    assert(simd_length(actual-expected)/ceiling < 0.0005)
                }
            }
        }
        print("Lightness hue anchors, gamut intersections, neutral preservation, recipe persistence and SDR/HDR GPU parity passed.")
    }
}
