import CoreImage
import ImageIO
@testable import Dark_Melon

@main struct BadHDRChecks {
    static func main() async throws {
        let space = ProcessingColorSpace.sRGB
        let context = CIContext(options:[.workingColorSpace:space.linear,.workingFormat:CIFormat.RGBAf])
        func pixels(_ image: CIImage) -> [Float] {
            var data = [Float](repeating:0,count:64*48*4)
            let normalized = image.transformed(by:CGAffineTransform(translationX:-image.extent.minX,y:-image.extent.minY))
                .transformed(by:CGAffineTransform(scaleX:64/image.extent.width,y:48/image.extent.height))
            context.render(normalized,toBitmap:&data,rowBytes:64*16,bounds:CGRect(x:0,y:0,width:64,height:48),format:.RGBAf,colorSpace:space.linear)
            return data
        }
        let effect = BadHDR()
        let constant = CIImage(color:CIColor(red:0.4,green:0.2,blue:0.1,alpha:0.5,colorSpace:space.linear)!)
            .cropped(to:CGRect(x:0,y:0,width:64,height:48))
        let identity = try effect.apply(to:constant,settings:BadHDRSettings(),whitePoint:0.8,weights:space.luminance)
        assert(identity === constant)
        let original = pixels(constant)
        let weights = space.luminance
        let grayLevel = 0.4 * weights.x + 0.2 * weights.y + 0.1 * weights.z
        for white in [0.2, 0.8, 1.0] {
            let output = pixels(try effect.apply(to:constant,settings:BadHDRSettings(strength:1),whitePoint:white,weights:space.luminance))
            for i in output.indices {
                let expected = i % 4 == 3 ? original[i] : original[i] * Float(1 - 0.5 * min(1, grayLevel / white))
                assert(abs(output[i] - expected) < 0.001,"Incorrect multiplication or alpha")
            }
            for input in [0.0, 0.02, 0.2, 0.4, 0.5, 0.8, 1.0, 1.2, 4.0] {
                let gray = CIImage(color:CIColor(red:input,green:input,blue:input,colorSpace:space.linear)!)
                    .cropped(to:constant.extent)
                for strength in [-4.0, -1.0, -0.25, 0.25, 1.0, 2.0, 4.0] {
                    let output = pixels(try effect.apply(to:gray,settings:BadHDRSettings(strength:strength),whitePoint:white,weights:space.luminance))
                    let expected = input * pow(1 - 0.5 * min(1,input / white), strength)
                    for i in output.indices where i % 4 != 3 {
                        assert(abs(Double(output[i]) - expected) < 0.003 * max(1, expected),"Incorrect flat-field compression")
                    }
                    assert(output[3] == 1,"Alpha changed")
                }
            }
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let store = LUTStore(directory:folder.appendingPathComponent("LUTs"))
        let file = folder.appendingPathComponent("warm.cube")
        var cube = "LUT_3D_SIZE 2\n"
        for b in 0...1 { for g in 0...1 { for r in 0...1 { cube += "\(0.02+Double(r)*0.8) \(0.01+Double(g)*0.7) \(Double(b)*0.6)\n" }}}
        try cube.write(to:file,atomically:true,encoding:.utf8)
        let lut = try store.importFile(file)
        let image = CIFilter(name:"CICheckerboardGenerator",parameters:["inputWidth":8,"inputSharpness":1,
            "inputColor0":CIColor(red:0.05,green:0.1,blue:0.2),"inputColor1":CIColor(red:0.9,green:0.6,blue:0.4)])!.outputImage!
            .cropped(to:CGRect(x:0,y:0,width:64,height:48))
        let sourcePixels = pixels(image)
        let radius = 50 * EffectResolution.scale(shortSide:48)
        let blurred = pixels(image.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:radius]).cropped(to:image.extent))
        for white in [0.4, 0.8, 1.0] {
            for strength in [-1.0, 1.0] {
                let output = pixels(try effect.apply(to:image,settings:BadHDRSettings(strength:strength),whitePoint:white,weights:weights))
                for pixel in stride(from:0,to:output.count,by:4) {
                    let y = Double(blurred[pixel]) * weights.x + Double(blurred[pixel+1]) * weights.y + Double(blurred[pixel+2]) * weights.z
                    let multiplier = pow(1 - 0.5 * min(1,max(0,y / white)),strength)
                    for channel in 0..<3 {
                        let i = pixel + channel
                        let expected = Double(sourcePixels[i]) * multiplier
                        assert(abs(Double(output[i]) - expected) < 0.003 * max(1,expected),"Incorrect luminance multiplication")
                        let ratio = Double(output[i] / sourcePixels[i])
                        assert(abs(ratio - multiplier) < 0.003 * max(1,multiplier),"Color ratios changed")
                        if strength > 0 { assert(output[i] <= sourcePixels[i] + 0.001) }
                        else { assert(output[i] >= sourcePixels[i] - 0.001) }
                    }
                    assert(abs(output[pixel+3] - sourcePixels[pixel+3]) < 0.0001,"Alpha changed")
                }
            }
        }
        let bitmap = context.createCGImage(image,from:image.extent,format:.RGBAh,colorSpace:space.linear)!
        let worker = RAWDeveloper(colorSpace:space,lutStore:store,interactive:true)
        for id: UUID? in [nil,lut] {
            var clean = ToneMapping(); clean.white = 0.8; clean.lutID = id; clean.setAutomaticHDRTarget()
            var bad = clean; bad.badHDR = BadHDRSettings(strength:0.6,radius:1.5)
            let before = try await worker.previews(bitmap,mapping:clean)
            let after = try await worker.previews(bitmap,mapping:bad)
            let baseSDR = pixels(CIImage(cgImage:before.sdr)), badSDR = pixels(CIImage(cgImage:after.sdr))
            assert(zip(baseSDR,badSDR).contains { abs($0-$1)>0.01 })
            assert(zip(pixels(CIImage(cgImage:before.hdr)),pixels(CIImage(cgImage:after.hdr))).contains { abs($0-$1)>0.01 })
            let preTone = try effect.apply(to:CIImage(cgImage:bitmap),settings:bad.badHDR,whitePoint:bad.white,weights:space.luminance)
            for hdr in [false,true] {
                let expected = try await worker.mappedImage(preTone,mapping:clean,hdr:hdr)
                let actual = try await worker.mappedImage(CIImage(cgImage:bitmap),mapping:bad,hdr:hdr)
                assert(zip(pixels(expected),pixels(actual)).allSatisfy { abs($0-$1)<0.001 },"BadHDR is not applied before tone mapping")
            }
            let singleSDR = try await worker.preview(bitmap,mapping:bad,hdr:false)
            // Direct bitmap and cached half-float paths can round to neighboring 8-bit SDR codes.
            assert(zip(badSDR,pixels(CIImage(cgImage:singleSDR))).allSatisfy { abs($0-$1) < 0.01 })
            let development = RAWDevelopment(preview:bitmap,linearSource:CIImage(cgImage:bitmap),url:file,
                width:64,height:48,whitePoint:nil,metadata:CameraMetadata(properties:[:]),isRAW:false,rawDefaults:nil,sourceHeadroom:1)
            let patch = try await worker.detail(development,mapping:bad,hdr:false,
                region:PreviewRegion(rect:CGRect(x:0,y:0,width:1,height:1),displayPixels:CGSize(width:64,height:48)))
            assert(zip(badSDR,pixels(CIImage(cgImage:patch.image))).allSatisfy { abs($0-$1) < 0.003 })

            let json = try JSONEncoder().encode(bad)
            assert(String(decoding:json,as:UTF8.self).contains("badHDR"))
            let restored = try JSONDecoder().decode(ToneMapping.self,from:json)
            assert(restored.badHDR == bad.badHDR)
            assert(SettingsPasteSelection().applying(bad,to:clean).badHDR == bad.badHDR)
            var settings = HEIFSettings(); settings.format = .tiff; settings.tiff16Bit = true
            for hdr in [false,true] {
                settings.tiffHDR = hdr
                let a = try await worker.exportImage(image,mapping:clean,settings:settings)
                let b = try await worker.exportImage(image,mapping:bad,settings:settings)
                let first = pixels(CIImage(data:a)!), second = pixels(CIImage(data:b)!)
                assert(zip(first,second).contains { abs($0-$1)>0.001 },"BadHDR did not affect export")
            }
        }
        print("PASS: half-radius luminance mask, signed strength, color ratios/alpha preservation, shared pre-tone stage, SDR/HDR preview/export with/without LUT and settings serialization/paste")
    }
}
