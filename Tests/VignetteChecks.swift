import Foundation
import CoreImage
@testable import Dark_Melon
@main struct Check {
 static func main() throws {
  let space=CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
  let context=CIContext(options:[.workingColorSpace:space,.workingFormat:CIFormat.RGBAf])
  let kernel=Vignette()
  let extent=CGRect(x:0,y:0,width:1000,height:1000)
  let image=CIImage(color:CIColor(red:2,green:1,blue:0.5,alpha:1,colorSpace:space)!).cropped(to:extent)
  let identity=try kernel.apply(to:image,settings:VignetteSettings(),transform:nil)
  assert(identity === image)
  func sample(_ image:CIImage,_ point:CGPoint)->Float {
   var data=[Float](repeating:0,count:4)
   context.render(image,toBitmap:&data,rowBytes:16,bounds:CGRect(x:point.x,y:point.y,width:1,height:1),format:.RGBAf,colorSpace:space)
   assert(abs(data[3]-1)<0.0001)
   assert(abs(data[0]-2*data[1])<0.001 && abs(data[1]-2*data[2])<0.001)
   return data[1]
  }
  for amount in [1.0,4.0] {
   let output=try kernel.apply(to:image,settings:VignetteSettings(amount:amount,spread:1),transform:nil)
   assert(abs(sample(output,CGPoint(x:500,y:500))-1)<0.001)
   let corner=sample(output,.zero)
   assert(abs(corner-Float(pow(2,-amount)))<0.002)
   assert(abs(corner-sample(output,CGPoint(x:999,y:999)))<0.001)
   assert(sample(output,CGPoint(x:500,y:0))>corner)
  }
  let narrow=try kernel.apply(to:image,settings:VignetteSettings(amount:2,spread:0),transform:nil)
  let wide=try kernel.apply(to:image,settings:VignetteSettings(amount:2,spread:1),transform:nil)
  assert(sample(wide,CGPoint(x:750,y:500))<sample(narrow,CGPoint(x:750,y:500)))
  for ratio in [0.0,5.0,10.0,11.0] {
   for points in [[CGPoint(x:0.15,y:0.1),CGPoint(x:0.9,y:0.2),CGPoint(x:0.8,y:0.9),CGPoint(x:0.1,y:0.8)], [CGPoint(x:0.5,y:0.1),CGPoint(x:0.9,y:0.5),CGPoint(x:0.5,y:0.9),CGPoint(x:0.1,y:0.5)]] {
    let transform=TransformSettings(points:points,ratioPosition:ratio,rotation:0,horizontal:0,vertical:0)
    let out=try kernel.apply(to:image,settings:VignetteSettings(amount:1,spread:1),transform:transform)
    for uv in [CGPoint(x:0,y:0),CGPoint(x:1,y:0),CGPoint(x:1,y:1),CGPoint(x:0,y:1),CGPoint(x:0.5,y:0.5)] {
     let pt=transform.sourcePoint(uv)
     let value=sample(out,CGPoint(x:pt.x*1000-0.5,y:(1-pt.y)*1000-0.5))
     assert(abs(value-(uv.x==0.5 ? 1:0.5))<0.004,"Geometry mismatch \(value)")
    }
   }
  }
  var mapping=ToneMapping();mapping.vignette=VignetteSettings(amount:3,spread:0.8)
  let recipe=DevelopmentRecipe(colorSpace:.sRGB,mapping:mapping)
  let decoded=try DevelopmentRecipe.decode(recipe.encoded());assert(decoded==recipe)
  var json=try JSONSerialization.jsonObject(with:recipe.encoded()) as! [String:Any]
  var m=json["mapping"] as! [String:Any];m.removeValue(forKey:"vignette");json["mapping"]=m
  let old=try DevelopmentRecipe.decode(JSONSerialization.data(withJSONObject:json));assert(old.mapping.vignette==VignetteSettings())
  assert(SettingsPasteSelection().applying(mapping,to:ToneMapping()).vignette==mapping.vignette)
  mapping.vignette.amount=33
  do { _=try DevelopmentRecipe.decode(DevelopmentRecipe(colorSpace:.sRGB,mapping:mapping).encoded());fatalError("Invalid accepted") } catch RecipeError.invalid { }
  print("PASS: vignette GPU exposure, center/corners/spread, rotated/perspective/aspect geometry, recipes and paste")
 }
}
