import CoreImage
import Foundation
@testable import Dark_Melon

@main struct MonochromeWorkflowChecks {
    static func main() async throws {
        let space = ProcessingColorSpace.sRGB
        let context = CIContext(options:[.workingColorSpace:space.linear,.workingFormat:CIFormat.RGBAf])
        let source = CIImage(color:CIColor(red:0.2,green:0.4,blue:0.6,colorSpace:space.linear)!)
            .cropped(to:CGRect(x:0,y:0,width:64,height:64))
        func read(_ image: CIImage) -> [Float] {
            var pixel = [Float](repeating:0,count:4)
            context.render(image,toBitmap:&pixel,rowBytes:16,bounds:CGRect(x:32,y:32,width:1,height:1),format:.RGBAf,colorSpace:space.linear)
            return pixel
        }
        let halation = Halation()
        var settings = HalationSettings()
        settings.inputCurve = 1
        settings.transmission = 0.2
        let mono = try read(halation.apply(to:source,source:source,settings:settings,hdrBrightness:10,ceiling:0,monochrome:true))
        for (actual,expected) in zip(mono.prefix(3),[0.3,0.6,0.9]) { assert(abs(Double(actual)-expected)<0.0001) }
        settings.transmission = 0.5
        let otherTransmission = try read(halation.apply(to:source,source:source,settings:settings,hdrBrightness:10,ceiling:0,monochrome:true))
        assert(zip(mono,otherTransmission).allSatisfy { abs($0-$1)<0.00001 })
        assert(settings.transmission == 0.5)
        let colored = try read(halation.apply(to:source,source:source,settings:settings,hdrBrightness:10,ceiling:0))
        assert(abs(colored[2]-0.6)<0.0001)
        let worker = RAWDeveloper(colorSpace:space)
        var mapping = ToneMapping()
        mapping.color.monochrome = true
        OKLabVertexWarp.setMonochrome(true,controls:&mapping.vertexWarp)
        let neutral = try await worker.mappedImage(source,mapping:mapping,hdr:false)
        mapping.whiteBalance = WhiteBalance(red:2,green:0.5,blue:1.2)
        let shifted = try await worker.mappedImage(source,mapping:mapping,hdr:false)
        assert(zip(read(neutral),read(shifted)).allSatisfy { abs($0-$1)<0.00001 })
        assert(mapping.whiteBalance.red == 2)
        print("Equal-channel monochrome Halation, transmission independence, preserved saved values and RGB WB bypass passed.")
    }
}
