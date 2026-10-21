import Foundation
import CoreImage
@testable import Dark_Melon
@main struct Check {
 static func main() async throws {
  let space=CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
  let context=CIContext(options:[.workingColorSpace:space,.workingFormat:CIFormat.RGBAf])
  let bounds=CGRect(x:0,y:0,width:32,height:32)
  func image(_ values:[Double])->CGImage {
   let ci=CIImage(color:CIColor(red:values[0],green:values[1],blue:values[2],alpha:1,colorSpace:space)!).cropped(to:bounds)
   return context.createCGImage(ci,from:bounds,format:.RGBAh,colorSpace:space)!
  }
  func pixel(_ image:CGImage)->[Float] {
   var p=[Float](repeating:0,count:4)
   context.render(CIImage(cgImage:image),toBitmap:&p,rowBytes:16,bounds:CGRect(x:16,y:16,width:1,height:1),format:.RGBAf,colorSpace:space)
   return p
  }
  let worker=RAWDeveloper(colorSpace:.sRGB)
  let values=[0.1,0.5,1.2]
  let source=image(values)
  for offset in [-0.02,0,0.02] {
   var mapping=ToneMapping();mapping.offset=offset
   for hdr in [false,true] {
    let actual=pixel(try await worker.preview(source,mapping:mapping,hdr:hdr))
    mapping.offset=0
    let expected=pixel(try await worker.preview(image(values.map{max(0,$0+offset)}),mapping:mapping,hdr:hdr))
    assert(zip(actual,expected).allSatisfy{abs($0-$1)<0.01})
    mapping.offset=offset
   }
   let recipe=DevelopmentRecipe(colorSpace:.sRGB,mapping:mapping)
   let decoded=try DevelopmentRecipe.decode(recipe.encoded());assert(decoded==recipe)
   assert(SettingsPasteSelection().applying(mapping,to:ToneMapping()).offset==offset)
  }
  var document=try JSONSerialization.jsonObject(with:DevelopmentRecipe(colorSpace:.sRGB,mapping:ToneMapping()).encoded()) as! [String:Any]
  var mapping=document["mapping"] as! [String:Any];mapping.removeValue(forKey:"offset");document["mapping"]=mapping
  let old=try DevelopmentRecipe.decode(JSONSerialization.data(withJSONObject:document));assert(old.mapping.offset==0)
  print("PASS: Offset SDR/HDR matches explicitly shifted linear input; recipes and paste preserve values; old recipes default to zero.")
 }
}
