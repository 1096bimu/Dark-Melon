import Foundation
import CoreImage
@testable import Dark_Melon
@main struct Check {
 static func main() async throws {
  let space=CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
  let context=CIContext()
  let source=CIImage(color:CIColor(red:0.25,green:0.25,blue:0.25,alpha:1,colorSpace:space)!)
  let preview=context.createCGImage(source,from:CGRect(x:0,y:0,width:64,height:32),format:.RGBAh,colorSpace:space)!
  let development=RAWDevelopment(preview:preview,linearSource:source.cropped(to:CGRect(x:0,y:0,width:100000,height:80000)),url:URL(fileURLWithPath:"/nonexistent/large.raw"),width:100000,height:80000,whitePoint:nil,metadata:CameraMetadata(properties:[:]),isRAW:true,rawDefaults:nil,sourceHeadroom:1)
  let worker=RAWDeveloper(colorSpace:.sRGB)
  for bins in [128,336] {
   let result=try await worker.buildHistogram(development,bins:bins)
   assert(result.histogram.count==3)
   assert(result.histogram.allSatisfy{$0.count==bins && $0.reduce(0,+)==64*32})
  }
  print("PASS: huge logical source and inaccessible URL use only the cached 64×32 preview; rebinning preserves sample count.")
 }
}
