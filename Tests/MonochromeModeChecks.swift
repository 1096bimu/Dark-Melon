import CoreImage
import Foundation
@testable import Dark_Melon

@main struct MonochromeModeChecks {
    static func main() throws {
        let space = ProcessingColorSpace.displayP3
        let pipeline = OKLabColorPipeline()
        let context = CIContext(options:[.workingColorSpace:space.linear,.workingFormat:CIFormat.RGBAf])
        var mapping = ToneMapping()
        mapping.vertexWarp[0].chroma = 0.5
        mapping.vertexWarp[0].hueOffset = 0.1
        mapping.vertexWarp[0].darkerHue = 0.4
        mapping.color.monochrome = true
        func render(_ color: ColorAdjustments, _ controls: [OKLabVertexAdjustment], ceiling: Double) throws -> [Float] {
            let input = CIImage(color:CIColor(red:0.7*ceiling,green:0.1*ceiling,blue:0.05*ceiling,colorSpace:space.linear)!).cropped(to:CGRect(x:0,y:0,width:1,height:1))
            let output = try pipeline.apply(input,color:color,vertices:controls,space:space,ceiling:ceiling,domainCeiling:ceiling)
            var pixel = [Float](repeating:0,count:4)
            context.render(output,toBitmap:&pixel,rowBytes:16,bounds:input.extent,format:.RGBAf,colorSpace:space.linear)
            return pixel
        }
        for ceiling in [1.0,8] {
            let mono = try render(mapping.color,mapping.vertexWarp,ceiling:ceiling)
            assert(abs(mono[0]-mono[1])/Float(ceiling)<0.00001 && abs(mono[1]-mono[2])/Float(ceiling)<0.00001)
            var density = mapping.vertexWarp
            density[0].lightness = -0.15
            let darker = try render(mapping.color,density,ceiling:ceiling)
            assert(darker[0] < mono[0])
            var color = mapping.color
            color.monochrome = false
            let restored = try render(color,mapping.vertexWarp,ceiling:ceiling)
            assert(abs(restored[0]-restored[1])/Float(ceiling)>0.1)
        }
        let recipe = DevelopmentRecipe(colorSpace:space,mapping:mapping)
        let decoded = try DevelopmentRecipe.decode(recipe.encoded())
        assert(decoded == recipe)
        let pasted = SettingsPasteSelection(items:[.vertices]).applying(mapping,to:ToneMapping())
        assert(pasted.color.monochrome)
        var legacy = try JSONSerialization.jsonObject(with:recipe.encoded()) as! [String:Any]
        var oldMapping = legacy["mapping"] as! [String:Any]
        var color = oldMapping["color"] as! [String:Any]
        color.removeValue(forKey:"monochrome");oldMapping["color"] = color
        var controls = oldMapping["vertexWarp"] as! [[String:Any]]
        for i in controls.indices { controls[i]["chroma"] = 0 }
        oldMapping["vertexWarp"] = controls;legacy["mapping"] = oldMapping
        let migrated = try DevelopmentRecipe.decode(JSONSerialization.data(withJSONObject:legacy))
        assert(migrated.mapping.color.monochrome && migrated.mapping.vertexWarp.allSatisfy { $0.chroma == 0 })
        var edited = mapping.vertexWarp
        edited[0].lightness = -0.1
        OKLabVertexWarp.setMonochrome(true, controls: &edited)
        assert(edited.allSatisfy { $0.chroma == 0 && $0.hueOffset == 0 && $0.darkerHue == 0 && $0.lighterHue == 0 })
        assert(edited[0].lightness == -0.1)
        OKLabVertexWarp.setMonochrome(false, controls: &edited)
        assert(edited.allSatisfy { $0.chroma == 1 && $0.hueOffset == 0 })
        assert(edited[0].lightness == -0.1)
        print("Monochrome SDR/HDR rendering, Density, default-color reset, recipe roundtrip, paste and legacy migration passed.")
    }
}
