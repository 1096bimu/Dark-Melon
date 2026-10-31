import CoreImage
import Foundation
@testable import Dark_Melon
@main struct PreviewTimingChecks {
 static func main() async throws {
  let space=CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
  let context=CIContext(options:[.workingColorSpace:space,.workingFormat:CIFormat.RGBAf])
  var pixels=[Float]()
  for y in 0..<32 { for x in 0..<32 { pixels += [Float(x)/32,Float(y)/32,0.15,1] } }
  let ci=CIImage(bitmapData:pixels.withUnsafeBytes { Data($0) },bytesPerRow:32*16,size:CGSize(width:32,height:32),format:.RGBAf,colorSpace:space)
  let source=context.createCGImage(ci,from:ci.extent,format:.RGBAf,colorSpace:space)!
  let interactive=RAWDeveloper(colorSpace:.sRGB,interactive:true)
  let reference=RAWDeveloper(colorSpace:.sRGB)
  var mapping=ToneMapping.fresh(isRAW:false,sourceHeadroom:2)
  mapping.hdf=0.05
  func sample(_ image:CGImage)->[Float] {
   var out=[Float](repeating:0,count:image.width*image.height*4)
   context.render(CIImage(cgImage:image),toBitmap:&out,rowBytes:image.width*16,
    bounds:CGRect(x:0,y:0,width:image.width,height:image.height),format:.RGBAf,colorSpace:space)
   return out
  }
  for iteration in 0..<6 {
   if iteration == 1 { mapping.concentration=0.4; mapping.tonePosition=0.12 }
   if iteration == 2 { mapping.color.saturationMid=0.7 }
   if iteration == 3 {
    mapping.transform=TransformSettings(points:[CGPoint(x:0.1,y:0.1),CGPoint(x:0.9,y:0.15),CGPoint(x:0.8,y:0.9),CGPoint(x:0.2,y:0.85)],ratioPosition:5,rotation:0,horizontal:0,vertical:0)
   }
   if iteration == 4 { mapping.hdrGain=0 }
   let a=try await interactive.previews(source,mapping:mapping)
   // Separate reference renderer uses the unbatched Core Image path.
   let b=try await reference.previews(source,mapping:mapping)
   precondition(a.gpuMilliseconds != nil && a.gpuMilliseconds! > 0)
   precondition(a.renderMilliseconds >= a.gpuMilliseconds!)
   for (lhs,rhs) in [(a.sdr,b.sdr),(a.hdr,b.hdr),(a.fullSDR,b.fullSDR),(a.fullHDR,b.fullHDR)] {
    precondition(lhs.width == rhs.width && lhs.height == rhs.height)
    let error=zip(sample(lhs),sample(rhs)).map { abs($0-$1) }.max()!
    // One 8-bit sRGB code near white is about 0.0089 in linear light.
    precondition(error < 0.009,"Batched pipeline changed pixels: \(error)")
   }
   print("Case \(iteration): GPU \(a.gpuMilliseconds!) ms; total \(a.renderMilliseconds) ms")
  }
  let cancelled = Task {
   withUnsafeCurrentTask { $0?.cancel() }
   return try await interactive.previews(source,mapping:mapping)
  }
  do { _ = try await cancelled.value; preconditionFailure("Cancelled render completed") }
  catch is CancellationError { }
  _ = try await interactive.previews(source,mapping:mapping)
  print("Preview batching, cache invalidation, cancellation and pixel checks passed")
 }
}
