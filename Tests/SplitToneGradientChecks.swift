import Foundation
import CoreImage
@testable import Dark_Melon
@main struct Check {
 static func main() async throws {
  let a=SIMD2<Double>(0.1,0.2),b=SIMD2<Double>(-0.1,0)
  assert(OKLabColor.interpolate(0,nodes:[(0.5,a)])==a)
  assert(OKLabColor.interpolate(2,nodes:[(0.5,a)])==a)
  let mid=OKLabColor.interpolate(0.5,nodes:[(0.25,a),(0.75,b)])
  assert(abs(mid.x)<1e-12 && abs(mid.y-0.1)<1e-12)
  for space in ProcessingColorSpace.allCases {
   for ceiling in [1.0,8.0] {
    for angle in stride(from:0.0,to:360,by:30) {
     let node=SplitToneNode(lightness:0.6*cbrt(ceiling),hue:angle,strength:1)
     let tint=OKLabColor.tint(node,ceiling:ceiling,space:space)
     let rgb=OKLabColor.linear(SIMD3(node.lightness,tint.x,tint.y),space:space)
     assert(rgb.min() > -0.00001 && rgb.max() < ceiling+0.00001)
    }
   }
  }
  let space=CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
  let context=CIContext(options:[.workingColorSpace:space,.workingFormat:CIFormat.RGBAf])
  let renderer=SplitToneGradient()
  var settings=SplitToneSettings();settings.nodes=[SplitToneNode(lightness:0.5,hue:30,strength:0.5)]
  for gray in [0.01,0.125,0.5,2.0] {
   let input=CIImage(color:CIColor(red:gray,green:gray,blue:gray,alpha:1,colorSpace:space)!).cropped(to:CGRect(x:0,y:0,width:4,height:4))
   let output=try renderer.apply(input,settings:settings,space:.sRGB,ceiling:8,domainCeiling:8)
   var data=[Float](repeating:0,count:4)
   context.render(output,toBitmap:&data,rowBytes:16,bounds:CGRect(x:0,y:0,width:1,height:1),format:.RGBAf,colorSpace:space)
   assert(data.allSatisfy{$0.isFinite} && data[0]>data[1] && data[1]>data[2] && data[3]==1)
   var none=settings;none.nodes=[]
   let identity=try renderer.apply(input,settings:none,space:.sRGB,ceiling:8,domainCeiling:8)
   assert(identity === input)
  }
  var mapping=ToneMapping();mapping.color.splitTone=settings
  let recipe=DevelopmentRecipe(colorSpace:.sRGB,mapping:mapping)
  let decoded=try DevelopmentRecipe.decode(recipe.encoded());assert(decoded==recipe)
  let worker=RAWDeveloper(colorSpace:.sRGB)
  let input=CIImage(color:CIColor(red:0.4,green:0.3,blue:0.2)).cropped(to:CGRect(x:0,y:0,width:16,height:16))
  let cg=context.createCGImage(input,from:input.extent,format:.RGBAh,colorSpace:space)!
  for hdr in [false,true] {_=try await worker.preview(cg,mapping:mapping,hdr:hdr)}
  print("PASS: one-node full-range tint, 3D chord interpolation, gamut limits, identity, SDR/HDR GPU rendering and recipes")
 }
}
