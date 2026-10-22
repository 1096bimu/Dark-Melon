import Foundation
import CoreImage
import simd
@testable import Dark_Melon

@main struct OrangeVertexChecks {
    static func main() throws {
        let pipeline=OKLabColorPipeline()
        for space in ProcessingColorSpace.allCases {
            let original=OKLabVertexWarp.field(controls:OKLabVertexWarp.defaults,space:space)
            assert(original.adjustments.count==7 && original.hues.count==7)
            var controls=OKLabVertexWarp.defaults
            controls[1].chroma=0.2
            controls[1].hueOffset = -0.4
            let field=OKLabVertexWarp.field(controls:controls,space:space)
            for step in 0..<360 {
                var h=Double(step)/180 * .pi
                if h<original.hues[0] { h+=2 * .pi }
                let p=SIMD3(0.6,0.1*cos(h),0.1*sin(h))
                if h>original.hues[2] { assert(simd_length(field.mapped(p)-p)<1e-9) }
            }
            let orange=original.centers[1]
            let result=field.mapped(orange)
            assert(abs(hypot(result.y,result.z)/hypot(orange.y,orange.z)-0.2)<1e-9)
            let gap=(0..<7).map { i in (i==6 ? original.hues[0]+2 * .pi : original.hues[i+1])-original.hues[i] }.min()!
            let radius=max(36,20/(2*sin(gap/2)))
            for i in 0..<7 { for j in i+1..<7 {
                let a=SIMD2(cos(original.hues[i]),sin(original.hues[i]))*radius
                let b=SIMD2(cos(original.hues[j]),sin(original.hues[j]))*radius
                assert(simd_length(a-b)>=20-1e-8)
            }}
            var mapping=ToneMapping()
            mapping.vertexWarp=controls
            let recipe=DevelopmentRecipe(colorSpace:space,mapping:mapping)
            let restored=try DevelopmentRecipe.decode(recipe.encoded())
            assert(restored.mapping.vertexWarp==controls)
            var document=try JSONSerialization.jsonObject(with:recipe.encoded()) as! [String:Any]
            var old=document["mapping"] as! [String:Any]
            old["vertexWarp"]=Array(repeating:["chroma":1.0,"lightness":0.0,"rotation":0.0],count:6)
            document["mapping"]=old
            let migrated=try DevelopmentRecipe.decode(JSONSerialization.data(withJSONObject:document))
            assert(migrated.mapping.vertexWarp.count==7)
            assert(migrated.mapping.vertexWarp.allSatisfy(\.isIdentity))
            let context=CIContext(options:[.workingColorSpace:space.linear])
            let image=CIImage(color:CIColor(red:0.8,green:0.25,blue:0.1,colorSpace:space.linear)!)
                .cropped(to:CGRect(x:0,y:0,width:1,height:1))
            for ceiling in [1.0,8.0] {
                let output=try pipeline.apply(image,color:ColorAdjustments(),vertices:controls,
                    space:space,ceiling:ceiling,domainCeiling:ceiling)
                var pixel=[Float](repeating:0,count:4)
                context.render(output,toBitmap:&pixel,rowBytes:16,bounds:image.extent,format:.RGBAf,colorSpace:space.linear)
                assert(pixel.allSatisfy(\.isFinite) && pixel[3]==1)
                let neutral=controls.map { v in var c=v;c.chroma=0;return c }
                let gray=try pipeline.apply(image,color:ColorAdjustments(),vertices:neutral,
                    space:space,ceiling:ceiling,domainCeiling:ceiling)
                context.render(gray,toBitmap:&pixel,rowBytes:16,bounds:image.extent,format:.RGBAf,colorSpace:space.linear)
                assert(abs(pixel[0]-pixel[1])<0.00001 && abs(pixel[1]-pixel[2])<0.00001)
            }
        }
        print("Seven-anchor GPU, orange locality, zero-chroma spacing, recipe round-trip and six-anchor migration passed.")
    }
}
