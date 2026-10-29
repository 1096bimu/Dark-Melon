import Foundation
import CoreImage
@testable import Dark_Melon
@main struct ColorChromeChecks {
 static func main() throws {
 let space=CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
 let context=CIContext(options:[.workingColorSpace:space,.workingFormat:CIFormat.RGBAf])
 let pipeline=OKLabColorPipeline()
 let rgb:[Float]=[0.3,0.25,0.2]
 let image=CIImage(color:CIColor(red:Double(rgb[0]),green:Double(rgb[1]),blue:Double(rgb[2]),alpha:1,colorSpace:space)!).cropped(to:CGRect(x:0,y:0,width:1,height:1))
  func lab(_ c:[Float])->[Double] {
   let r=Double(c[0]),g=Double(c[1]),b=Double(c[2])
   let l=cbrt(0.4122214708*r+0.5363325363*g+0.0514459929*b)
   let m=cbrt(0.2119034982*r+0.6806995451*g+0.1073969566*b)
   let s=cbrt(0.0883024619*r+0.2817188376*g+0.6299787005*b)
   return [0.2104542553*l+0.793617785*m-0.0040720468*s,1.9779984951*l-2.428592205*m+0.4505937099*s,0.0259040371*l+0.7827717662*m-0.808675766*s]
  }

 let original=lab(rgb), chroma=hypot(lab(rgb)[1],lab(rgb)[2])
 for amount in [0.0,0.5,1.0,1.5] {
  var color=ColorAdjustments()
  color.colorChrome=true
  color.saturationStart=amount; color.saturationMid=amount; color.saturationEnd=amount; color.saturationHDR=amount
  let output=try pipeline.apply(image,color:color,vertices:OKLabVertexWarp.defaults,space:.sRGB,ceiling:1,domainCeiling:1)
  var pixel=[Float](repeating:0,count:4)
  context.render(output,toBitmap:&pixel,rowBytes:16,bounds:image.extent,format:.RGBAf,colorSpace:space)
  let result=lab(pixel)
  precondition(abs(result[0]-(original[0]+chroma*(1-amount)))<0.0001)
  precondition(abs(hypot(result[1],result[2])-chroma*amount)<0.0001)
 }

 for amount in [0.5,1.5] {
  var vertices=OKLabVertexWarp.defaults
  for i in vertices.indices { vertices[i].chroma=amount }
  var color=ColorAdjustments(); color.colorChrome=true
  let output=try pipeline.apply(image,color:color,vertices:vertices,space:.sRGB,ceiling:1,domainCeiling:1)
  var pixel=[Float](repeating:0,count:4)
  context.render(output,toBitmap:&pixel,rowBytes:16,bounds:image.extent,format:.RGBAf,colorSpace:space)
  let result=lab(pixel)
  precondition(abs(result[0]-(original[0]+chroma*(1-amount)))<0.0001)
  precondition(abs(hypot(result[1],result[2])-chroma*amount)<0.0001)
 }
 var mapping=ToneMapping(); mapping.color.colorChrome=true
 let restored=try JSONDecoder().decode(ToneMapping.self,from:JSONEncoder().encode(mapping))
 precondition(restored.color.colorChrome)
 precondition(SettingsPasteSelection(items:[.colorChrome]).applying(mapping,to:ToneMapping()).color.colorChrome)
 print("Color Chrome: GPU lightness/chroma trade in both directions, identity, persistence and paste passed.")
 }
}
