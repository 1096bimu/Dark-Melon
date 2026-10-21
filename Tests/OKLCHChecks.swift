import Foundation
import CoreImage
@testable import Dark_Melon
@main struct Check {
 static func main() async throws {
  for space in ProcessingColorSpace.allCases { print("Maximum chroma \(space.rawValue): \(OKLCHGamut.maxima[space]!)") }
  let pipeline=OKLabColorPipeline()
  let space=CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
  let context=CIContext(options:[.workingColorSpace:space,.workingFormat:CIFormat.RGBAf])
  let functions=ColorPixelKernel.functions
  let probe=CIColorKernel(source:functions + "kernel vec4 probe(float x) { float y=chromaMultiplier(x,vec4(0.0,1.0,0.5,2.0),2.0); return vec4(y,y,y,1.0); }")!
  for (x,expected) in [(0.0,0.0),(0.25,0.5),(0.5,1.0),(0.75,0.75),(1.0,0.5),(1.5,1.25),(2.0,2.0),(3.0,2.0)] {
   let out=probe.apply(extent:CGRect(x:0,y:0,width:1,height:1),arguments:[x])!
   var pixel=[Float](repeating:0,count:4)
   context.render(out,toBitmap:&pixel,rowBytes:16,bounds:out.extent,format:.RGBAf,colorSpace:space)
   assert(abs(Double(pixel[0])-expected)<0.0001)
  }
  var oldDoc=try JSONSerialization.jsonObject(with:DevelopmentRecipe(colorSpace:.sRGB,mapping:ToneMapping()).encoded()) as! [String:Any]
  var oldMap=oldDoc["mapping"] as! [String:Any]
  oldMap["color"]=["saturationStart":0.5,"saturationEnd":1.5,"saturationCurve":1.0]
  oldDoc["mapping"]=oldMap
  let migrated=try DevelopmentRecipe.decode(JSONSerialization.data(withJSONObject:oldDoc))
  assert(migrated.mapping.color.saturationMid==1.25 && migrated.mapping.color.saturationHDR==1.5)
  let roundtrip=try DevelopmentRecipe.decode(migrated.encoded());assert(roundtrip==migrated)
  let rgb=[0.4,0.2,0.1]
  let image=CIImage(color:CIColor(red:rgb[0],green:rgb[1],blue:rgb[2],alpha:1,colorSpace:space)!).cropped(to:CGRect(x:0,y:0,width:8,height:8))
  func lab(_ c:[Float])->[Double] {
   let r=Double(c[0]),g=Double(c[1]),b=Double(c[2])
   let l=cbrt(0.4122214708*r+0.5363325363*g+0.0514459929*b)
   let m=cbrt(0.2119034982*r+0.6806995451*g+0.1073969566*b)
   let s=cbrt(0.0883024619*r+0.2817188376*g+0.6299787005*b)
   return [0.2104542553*l+0.793617785*m-0.0040720468*s,1.9779984951*l-2.428592205*m+0.4505937099*s,0.0259040371*l+0.7827717662*m-0.808675766*s]
  }
  let original=lab(rgb.map(Float.init))
  for amount in [0.0,0.5,1.0,2.0] {
   var color=ColorAdjustments()
   color.saturationStart=amount; color.saturationMid=amount; color.saturationEnd=amount; color.saturationHDR=amount
   let output=try pipeline.apply(image,color:color,vertices:Array(repeating:OKLabVertexAdjustment(),count:6),space:.sRGB,ceiling:1,domainCeiling:8)
   var data=[Float](repeating:0,count:4)
   context.render(output,toBitmap:&data,rowBytes:16,bounds:CGRect(x:0,y:0,width:1,height:1),format:.RGBAf,colorSpace:space)
   let result=lab(data)
   assert(abs(result[0]-original[0])<0.0002)
   if amount<=1 {assert(abs(result[1]-original[1]*amount)<0.0002 && abs(result[2]-original[2]*amount)<0.0002)}
   assert(data.allSatisfy{$0.isFinite} && data[3]==1)
  }
  for space in ProcessingColorSpace.allCases {
   let worker=RAWDeveloper(colorSpace:space)
   let cg=context.createCGImage(image,from:image.extent,format:.RGBAh,colorSpace:space.linear)!
   var mapping=ToneMapping();mapping.color.saturationStart=0.5;mapping.color.luminanceSaturationEnd=1.5
   for hdr in [false,true] {_=try await worker.preview(cg,mapping:mapping,hdr:hdr)}
  }
  print("PASS: GPU OKLCH chroma scaling, lightness preservation, neutral/identity, gamut limiting, SDR/HDR in all working spaces")
 }
}
