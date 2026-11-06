import Foundation
import CoreImage
import ImageIO
@testable import Dark_Melon

@main struct DustCorrectionChecks {
    static func main() async throws {
        let size=CGSize(width:240,height:160)
        let space=CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
        let context=CIContext(options:[.workingColorSpace:space])
        var spot=DustSpot(center:CGPoint(x:0.32,y:0.6),angle:0.3,length:0.6,radius:0.06,feather:0.07,attenuation:0.4)
        var values=[Float]()
        for y in 0..<160 { for x in 0..<240 {
            let distance=hypot((Double(x)+0.5)/160-spot.center.x*1.5,((Double(y)+0.5)/160)-spot.center.y)
            let t=Float(spot.transmission(distance))
            values += [2*t,0.5*t,0.25*t,1]
        }}
        let source=CIImage(bitmapData:values.withUnsafeBytes{Data($0)},bytesPerRow:240*16,size:size,format:.RGBAf,colorSpace:space)
        func pixels(_ image:CIImage)->[Float] {
            let w=Int(image.extent.width),h=Int(image.extent.height)
            var data=[Float](repeating:0,count:w*h*4)
            context.render(image,toBitmap:&data,rowBytes:w*16,bounds:image.extent,format:.RGBAf,colorSpace:space)
            return data
        }
        let renderer=DustCorrection()
        for exif:Int32 in 1...8 { for turn in 0..<4 { for mirror in [false,true] {
            let orientation=SourceOrientation(quarterTurns:turn,mirrored:mirror)
            let geometry=DustGeometry(exif:exif,orientation:orientation)
            let p=CGPoint(x:0.21,y:0.67),roundtrip=geometry.native(geometry.display(p))
            precondition(hypot(roundtrip.x-p.x,roundtrip.y-p.y)<1e-12)
            let oriented=orientation.apply(to:source.oriented(forExifOrientation:exif))
            precondition(geometry.nativeSize(oriented.extent.size)==size)
            let corrected=try renderer.apply(oriented,spots:[spot],geometry:geometry)
            let output=pixels(corrected)
            for i in stride(from:0,to:output.count,by:4) {
                precondition(abs(output[i]-2)<0.004 && abs(output[i+1]-0.5)<0.002 && output[i+3]==1,"Orientation correction mismatch \(exif) \(turn) \(mirror): \(output[i])")
            }
        }}}
        let url=URL(fileURLWithPath:"/tmp/dust-synthetic.tif")
        let preview=context.createCGImage(source,from:source.extent,format:.RGBAh,colorSpace:space)!
        let metadata=CameraMetadata(properties:[:],url:url,isRAW:false,type:nil)
        let development=RAWDevelopment(preview:preview,linearSource:source,url:url,width:240,height:160,whitePoint:nil,metadata:metadata,isRAW:false,rawDefaults:nil,sourceHeadroom:1)
        let worker=RAWDeveloper()
        let sampled=try await worker.dustProfile(development,spot:spot,spots:[spot])
        let (sampleFit,_)=try DustFitter.fit(sampled,spot:spot,nativeSize:size)
        precondition(abs(sampleFit.attenuation-spot.attenuation)<0.02,"Rotated strip sampling fit")
        let corrected=try renderer.apply(source,spots:[spot],geometry:DustGeometry())
        let patch=CGRect(x:30,y:30,width:70,height:70)
        let patchPixels=pixels(corrected.cropped(to:patch))
        precondition(stride(from:0,to:patchPixels.count,by:4).allSatisfy { abs(patchPixels[$0]-2)<0.004 }, "Detail patch coordinate mismatch")
        let identity=try renderer.apply(source,spots:[],geometry:DustGeometry())
        precondition(zip(pixels(source),pixels(identity)).allSatisfy{ $0 == $1 })
        for shift in [-0.06,0,0.06] { for slope in [-0.4,0,0.4] {
            let samples=(0..<256).map { i -> Double in
                let x=(Double(i)/255-0.5)*spot.length
                return (0.6+slope*x)*spot.transmission(abs(x-shift))
            }
            var seed=spot;seed.attenuation=0
            let (fit,profile)=try DustFitter.fit(DustProfile(values:samples,stripWidth:0),spot:seed,nativeSize:size)
            let offset=hypot((fit.center.x-spot.center.x)*1.5,fit.center.y-spot.center.y)
            precondition(abs(offset-abs(shift))<0.003,"Center fit")
            precondition(abs(fit.attenuation-spot.attenuation)<0.01,"Attenuation fit \(fit.attenuation)")
            let error=zip(samples,profile.background).enumerated().map { i,p in
                let x=(Double(i)/255-0.5)*spot.length
                return abs(p.0/fit.transmission(abs(x-shift))-p.1)
            }.max()!
            precondition(error<0.01,"Residual \(error)")
        }}
        do { _=try DustFitter.fit(DustProfile(values:Array(repeating:0.5,count:128),stripWidth:0),spot:spot,nativeSize:size);fatalError("Flat line accepted") } catch DustFailure.fit {}
        var mapping=ToneMapping();mapping.dustSpots=[spot]
        let recipe=DevelopmentRecipe(colorSpace:.sRGB,mapping:mapping)
        let roundtrip=try DevelopmentRecipe.decode(recipe.encoded())
        precondition(roundtrip.mapping.dustSpots == [spot])
        let pasted=SettingsPasteSelection(items:[.dustCorrection]).applying(mapping,to:ToneMapping())
        precondition(pasted.dustSpots == [spot])
        let old=try DevelopmentRecipe.decode(DevelopmentRecipe(colorSpace:.sRGB,mapping:ToneMapping()).encoded())
        precondition(old.mapping.dustSpots == nil)
        // Source baking: later previews must not apply the same spots a second time.
        let file=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".png")
        defer { try? FileManager.default.removeItem(at:file) }
        let encoded=context.createCGImage(source,from:source.extent,format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)!
        let destination=CGImageDestinationCreateWithURL(file as CFURL,"public.png" as CFString,1,nil)!
        CGImageDestinationAddImage(destination,encoded,nil);precondition(CGImageDestinationFinalize(destination))
        let baking=RAWDeveloper(interactive:true)
        let clean=try await baking.develop(file)
        let baked=try await baking.develop(file,dustSpots:[spot])
        precondition(baked.dustSpots == [spot] && baked.fullResolutionReady)
        let expected=try renderer.apply(clean.linearSource,spots:[spot],geometry:clean.dustGeometry)
        precondition(zip(pixels(expected),pixels(baked.linearSource)).allSatisfy{abs($0-$1)<0.003},"Baked source pixels")
        var neutral=ToneMapping.fresh(isRAW:false,sourceHeadroom:1)
        neutral.grain.strength=0;neutral.halation.inputCurve=0
        var withDust=neutral;withDust.dustSpots=[spot]
        let a=try await baking.previews(baked.preview,mapping:neutral)
        let b=try await baking.previews(baked.preview,mapping:withDust)
        precondition(zip(pixels(CIImage(cgImage:a.sdr)),pixels(CIImage(cgImage:b.sdr))).allSatisfy{abs($0-$1)<0.0001},"Correction repeated during preview")
        let refitProfile=try await baking.dustProfile(baked,spot:spot,spots:[spot])
        let originalProfile=try await baking.dustProfile(clean,spot:spot,spots:[spot])
        precondition(zip(refitProfile.values,originalProfile.values).allSatisfy{abs($0-$1)<0.001},"Refit sampled corrected pixels")
        let removed=try await baking.replacingSourceCorrections(baked,spots:[],canvas:size)
        precondition(removed.dustSpots.isEmpty)
        precondition(zip(pixels(removed.linearSource),pixels(clean.linearSource)).allSatisfy{abs($0-$1)<0.001})
        // The source cache must replace, rather than retain, the uncorrected variant.
        let stamp=RAWImageCache.FileStamp(file)!
        let cache=RAWImageCache(memory:8*1024*1024*1024)
        var rawClean=RAWDevelopment(preview:clean.preview,linearSource:clean.linearSource,url:file,width:240,height:160,whitePoint:nil,metadata:metadata,isRAW:true,rawDefaults:RAWSettings(),sourceHeadroom:1)
        cache.insert(rawClean,stamp:stamp,space:.sRGB,settings:nil,balance:nil)
        precondition(cache.lookup(stamp,space:.sRGB,settings:nil,balance:nil) != nil)
        rawClean.dustSpots=[spot]
        cache.insert(rawClean,stamp:stamp,space:.sRGB,settings:nil,balance:nil)
        precondition(cache.lookup(stamp,space:.sRGB,settings:nil,balance:nil) == nil)
        precondition(cache.lookup(stamp,space:.sRGB,settings:nil,balance:nil,dustSpots:[spot]) != nil)
        print("Baked-source checks passed: corrected RGB source, no per-preview reapplication, uncorrected refit sampling, removal, and cache replacement.")
        spot.attenuation=1
        precondition(!spot.isValid)
        print("Dust checks passed: 64 orientation/mirror cases, HDR RGB/alpha, identity, fitting, old/new recipes and paste.")
    }
}
