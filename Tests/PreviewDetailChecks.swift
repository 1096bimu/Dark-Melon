import Foundation
import CoreImage
import AppKit
@testable import Dark_Melon
@main struct Check {
 @MainActor static func main() async throws {
  let space=CGColorSpace(name:CGColorSpace.linearSRGB)!
  let ctx=CIContext(options:[.workingColorSpace:space,.workingFormat:CIFormat.RGBAf])
  let size=CGSize(width:1024,height:768)
  let bounds=CGRect(origin:.zero,size:size)
  let checker=CIFilter(name:"CICheckerboardGenerator",parameters:["inputWidth":4,"inputSharpness":1,"inputColor0":CIColor(red:0.03,green:0.08,blue:0.12),"inputColor1":CIColor(red:0.9,green:0.65,blue:0.4)])!.outputImage!.cropped(to:bounds)
  let cg=ctx.createCGImage(checker,from:bounds,format:.RGBAh,colorSpace:space)!
  let source=CIImage(cgImage:cg)
  let low=source.transformed(by:CGAffineTransform(scaleX:0.25,y:0.25))
  let lowCG=ctx.createCGImage(low,from:low.extent,format:.RGBAh,colorSpace:space)!
  let dev=RAWDevelopment(preview:lowCG,linearSource:source,url:URL(fileURLWithPath:"/tmp/detail-synthetic"),width:1024,height:768,whitePoint:nil,metadata:CameraMetadata(properties:[:]),isRAW:false,rawDefaults:nil,sourceHeadroom:1)
  let worker=RAWDeveloper(colorSpace:.sRGB)
  let overview=try await worker.overview(dev,canvas:CGSize(width:256,height:192))
  assert(overview.width==256 && overview.height==192)
  let repeated=try await worker.overview(dev,canvas:CGSize(width:256,height:192))
  assert(overview === repeated)
  assert(PreviewResolution.requiredScale(display:CGSize(width:256,height:192),output:size)==0.25)
  var mapping=ToneMapping();mapping.white=0.7;mapping.concentration=0.2;mapping.hdrTarget=4;mapping.hdrGain=1.1
  mapping.clarity=0.5;mapping.clarityRadius=90;mapping.hdf=0.12;mapping.hdfRadius=200
  mapping.halation.inputCurve=0.8;mapping.halation.transmission=0.3
  // Include procedural grain: patch renders keep full-image effect sizing.
  mapping.grain.strength=0.3
  mapping.vignette=VignetteSettings(amount:2,spread:0.7)
  for transformed in [false,true] {
   if transformed {
    mapping.transform=TransformSettings(points:[CGPoint(x:0.1,y:0.1),CGPoint(x:0.9,y:0.15),CGPoint(x:0.8,y:0.9),CGPoint(x:0.2,y:0.85)],ratioPosition:5,rotation:0,horizontal:0,vertical:0)
   }
   let output=mapping.transform?.resolution(width:1024,height:768,estimate:.maximum) ?? size
   for hdr in [false,true] {
    let region=PreviewRegion(rect:CGRect(x:0.35,y:0.3,width:0.2,height:0.25),displayPixels:output)
    let patch=try await worker.detail(dev,mapping:mapping,hdr:hdr,region:region)
    assert(patch.image.width<cg.width && patch.image.height<cg.height)
    assert(patch.covers(region,sourceID:dev.id,mapping:mapping,hdr:hdr,outputSize:output))
    let full=try await worker.preview(cg,mapping:mapping,hdr:hdr)
    let rect=CGRect(x:(patch.rect.minX*Double(full.width)).rounded(),y:(patch.rect.minY*Double(full.height)).rounded(),width:Double(patch.image.width),height:Double(patch.image.height))
    func pixels(_ image:CIImage,_ rect:CGRect)->[Float] {
     var data=[Float](repeating:0,count:Int(rect.width*rect.height)*4)
     ctx.render(image,toBitmap:&data,rowBytes:Int(rect.width)*16,bounds:rect,format:.RGBAf,colorSpace:space)
     return data
    }
    let expected=pixels(CIImage(cgImage:full),rect)
    let actual=pixels(CIImage(cgImage:patch.image),CGRect(x:0,y:0,width:Double(patch.image.width),height:Double(patch.image.height)))
    let maxError=zip(expected,actual).map{abs($0-$1)}.max()!
    assert(maxError<0.025,"ROI mismatch \(maxError)")
    print("\(hdr ? "HDR":"SDR") transform=\(transformed): \(patch.image.width)×\(patch.image.height) patch, full-render max error \(maxError)")
   }
  }
  let viewport=PreviewViewport();viewport.zoom=2;viewport.offset=CGPoint(x:30,y:0)
  let view=HDRImagePreview.ImageDisplay(viewport:viewport)
  view.frame=CGRect(x:0,y:0,width:200,height:150)
  var reported:PreviewRegion?
  view.regionChanged={reported=$0}
  let displayed=PreviewDetail(image:overview,rect:CGRect(x:0.2,y:0.3,width:0.2,height:0.25),scale:0.25,sourceID:dev.id,mapping:mapping,hdr:false)
  view.display(overview,sourceSize:size,detail:displayed,hdr:false,sourceID:dev.id)
  try await Task.sleep(for:.milliseconds(20))
  let imageLayer=view.layer!.sublayers![0]
  let detailLayer=imageLayer.sublayers![0]
  assert(detailLayer.frame == CGRect(x:80,y:90,width:80,height:75))
  assert(abs(reported!.rect.minX-0.175)<0.000001 && reported!.rect.minY==0.25)
  assert(imageLayer.magnificationFilter == .linear)
  let cancelled = Task { try await worker.detail(dev,mapping:mapping,hdr:true,
      region:PreviewRegion(rect:CGRect(x:0.2,y:0.2,width:0.2,height:0.2),displayPixels:size)) }
  cancelled.cancel()
  do { _ = try await cancelled.value; assertionFailure("Cancelled detail rendered") }
  catch is CancellationError { }
  print("PASS: adaptive overview/cache, bounded viewport, full-resolution SDR/HDR and effect neighborhoods.")
 }
}
