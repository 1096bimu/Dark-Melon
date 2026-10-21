import Foundation
import CoreImage
import simd
@testable import Dark_Melon

@main struct Check {
 static func main() throws {
  let pipeline=OKLabColorPipeline()
  for space in ProcessingColorSpace.allCases {
   let matrix=ScopeProjection.matrix(.sRGB).inverse * ScopeProjection.matrix(space)
   let context=CIContext(options:[.workingColorSpace:space.linear,.workingFormat:CIFormat.RGBAf])
   // Each edited vertex has exactly zero influence outside its two neighboring faces.
   for index in 0..<6 {
    var controls=Array(repeating:OKLabVertexAdjustment(),count:6)
    controls[index]=OKLabVertexAdjustment(chroma:0,lightness:0.25,rotation:1)
    let field=OKLabVertexWarp.field(controls:controls,space:space)
    let lo=index==0 ? field.hues[5]-2 * .pi:field.hues[index-1]
    let hi=index==5 ? field.hues[0]+2 * .pi:field.hues[index+1]
    for step in 0..<720 {
     var hue=Double(step)/720*2 * .pi
     while hue<lo { hue += 2 * .pi }
     while hue>=lo+2 * .pi { hue -= 2 * .pi }
     if hue>hi {
      for l in [0.2,0.5,0.8] {
       let p=SIMD3(l,0.1*cos(hue),0.1*sin(hue))
       assert(simd_length(field.mapped(p)-p)<1e-12)
      }
     }
    }
    for hue in [lo,hi] {
     let p=SIMD3(0.5,0.1*cos(hue),0.1*sin(hue))
     assert(simd_length(field.mapped(p)-p)<1e-12)
     let epsilon=1e-5
     let near=SIMD3(0.5,0.1*cos(hue+epsilon),0.1*sin(hue+epsilon))
     assert(simd_length(field.mapped(near)-near)<1e-8)
    }
   }
   for amount in [0.0,0.5,1.0] {
    let controls=Array(repeating:OKLabVertexAdjustment(chroma:amount),count:6)
    let field=OKLabVertexWarp.field(controls:controls,space:space)
    var pixels=[Float]()
    for r in 0...10 { for g in 0...10 { for b in 0...10 {
     let rgb=SIMD3(Double(r)/10,Double(g)/10,Double(b)/10)
     let lab=OKLabVertexWarp.lab(matrix*rgb), result=field.mapped(lab)
     assert(abs(result.x-lab.x)<1e-6 && abs(result.y-lab.y*amount)<1e-6 && abs(result.z-lab.z*amount)<1e-6)
     pixels += [Float(rgb.x),Float(rgb.y),Float(rgb.z),1]
    } } }
    let count=pixels.count/4
    let data=pixels.withUnsafeBytes { Data($0) }
    let image=CIImage(bitmapData:data,bytesPerRow:count*16,size:CGSize(width:count,height:1),format:.RGBAf,colorSpace:space.linear)
    for ceiling in [1.0,8.0] {
     let output=try pipeline.apply(image,color:ColorAdjustments(),vertices:controls,space:space,ceiling:ceiling,domainCeiling:ceiling)
     var values=[Float](repeating:0,count:pixels.count)
     context.render(output,toBitmap:&values,rowBytes:count*16,bounds:image.extent,format:.RGBAf,colorSpace:space.linear)
     assert(values.allSatisfy(\.isFinite))
     for i in stride(from:0,to:values.count,by:4) {
      assert(values[i+3]==1)
      if amount==0 { assert(abs(values[i]-values[i+1])<0.00002 && abs(values[i]-values[i+2])<0.00002) }
     }
    }
   }
   var controls=Array(repeating:OKLabVertexAdjustment(),count:6)
   controls[0]=OKLabVertexAdjustment(chroma:0.7,lightness:0.03,rotation:0.6)
   let field=OKLabVertexWarp.field(controls:controls,space:space)
   for i in 0..<8 {
    let p=field.centers[i], q=field.mapped(p)
    if i != 0 { assert(simd_length(p-q)<1e-8) }
    else {
     let angle=OKLabVertexWarp.rotationAngle(index:0,amount:0.6,space:space)
     let target=SIMD3(p.x+0.03,(p.y*cos(angle)-p.z*sin(angle))*0.7,(p.y*sin(angle)+p.z*cos(angle))*0.7)
     assert(simd_length(target-q)<1e-8)
    }
   }
  }
  // Regression image supplied by the user: every pixel must become neutral.
  let url=URL(fileURLWithPath:"/Users/chen/Demo RAW/19. FOUR-COLOR-GRADIENT.png")
  if let image=CIImage(contentsOf:url) {
   let space=ProcessingColorSpace.sRGB
   let context=CIContext(options:[.workingColorSpace:space.linear,.workingFormat:CIFormat.RGBAf])
   let output=try pipeline.apply(image,color:ColorAdjustments(),vertices:Array(repeating:OKLabVertexAdjustment(chroma:0),count:6),space:space,ceiling:1,domainCeiling:1)
   let small=output.transformed(by:CGAffineTransform(scaleX:0.25,y:0.25))
   let width=Int(small.extent.width),height=Int(small.extent.height)
   var values=[Float](repeating:0,count:width*height*4)
   context.render(small,toBitmap:&values,rowBytes:width*16,bounds:small.extent,format:.RGBAf,colorSpace:space.linear)
   var error:Float=0
   for i in stride(from:0,to:values.count,by:4) { error=max(error,abs(values[i]-values[i+1]),abs(values[i]-values[i+2])) }
   assert(error<0.00002)
   try context.writePNGRepresentation(of:small,to:URL(fileURLWithPath:"/tmp/darkmelon-oklab-neutral.png"),format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)
   print("Gradient residual RGB difference: \(error)")
  }
  print("PASS: local hue support, smooth boundary, uniform chroma scaling, exact anchors, GPU neutral volume in all three gamuts at SDR/HDR, alpha and finite output")
 }
}
