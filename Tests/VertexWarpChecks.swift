import Foundation
import CoreImage
@testable import Dark_Melon
@main struct Check {
 static func main() throws {
  for gamut in ProcessingColorSpace.allCases {
   let hues=OKLabVertexWarp.vertexHues[gamut]!
   for i in 0..<7 {
    let j=(i+1)%7
    let a=hues[i]+OKLabVertexWarp.rotationAngle(index:i,amount:1,space:gamut)
    let b=hues[j]+(j==0 ? 2 * .pi : 0)+OKLabVertexWarp.rotationAngle(index:j,amount:-1,space:gamut)
    assert(abs(a-b)<1e-12)
   }
  }
  let space=CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
  let context=CIContext(options:[.workingColorSpace:space,.workingFormat:CIFormat.RGBAf])
  let renderer=OKLabVertexWarp()
  func source(_ c:SIMD3<Double>)->CIImage {
   CIImage(color:CIColor(red:c.x,green:c.y,blue:c.z,alpha:1,colorSpace:space)!).cropped(to:CGRect(x:0,y:0,width:4,height:4))
  }
  var controls=Array(repeating:OKLabVertexAdjustment(),count:7)
  let input=source(SIMD3(0.5,0.3,0.1))
  let bypass=try renderer.apply(input,controls:controls,space:.sRGB,ceiling:1);assert(bypass === input)
  for i in 0..<7 {
   controls=Array(repeating:OKLabVertexAdjustment(),count:7)
   controls[i].chroma=0.7;controls[i].lightness=0.03;controls[i].rotation=0.6
   for j in 0..<8 {
    let rgb=j<6 ? OKLabVertexWarp.vertices[j] : SIMD3<Double>(repeating:j==6 ? 0:1)
    let output=try renderer.apply(source(rgb),controls:controls,space:.sRGB,ceiling:1)
    var values=[Float](repeating:0,count:4)
    context.render(output,toBitmap:&values,rowBytes:16,bounds:CGRect(x:0,y:0,width:1,height:1),format:.RGBAf,colorSpace:space)
    let actual=OKLabVertexWarp.lab(SIMD3(Double(values[0]),Double(values[1]),Double(values[2])))
    var expected=OKLabVertexWarp.lab(rgb)
    if j==i {
     let angle=OKLabVertexWarp.rotationAngle(index:i,amount:0.6,space:.sRGB)
     let a=expected.y,b=expected.z
     expected.x += 0.03;expected.y=(a*cos(angle)-b*sin(angle))*0.7;expected.z=(a*sin(angle)+b*cos(angle))*0.7
    }
    // The shared pipeline now fits only the final color to the output gamut.
    let chroma=hypot(expected.y,expected.z)
    let maximum=OKLabColor.maximumChroma(lightness:expected.x,hue:atan2(expected.z,expected.y)*180 / .pi,ceiling:1,space:.sRGB)
    let expectedRGB=OKLabColor.linear(expected,space:.sRGB)
    if (expectedRGB.min() < -0.000001 || expectedRGB.max() > 1.000001) && chroma>maximum && chroma>0 { expected.y *= maximum/chroma; expected.z *= maximum/chroma }
    if abs(actual.x-expected.x)>=0.0001 || abs(actual.y-expected.y)>=0.0001 || abs(actual.z-expected.z)>=0.0001 { fatalError("i=\(i) j=\(j) actual=\(actual) expected=\(expected)") }
    assert(values[3]==1)
   }
  }
  print("PASS: GPU identity, gamut-fitted six-vertex edits, unedited vertices fixed, black/white fixed, alpha preserved")
 }
}
