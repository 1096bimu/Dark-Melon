import CoreImage
import Foundation
@testable import Dark_Melon

@main struct RAWMaxRangeChecks {
    static func main() async throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        var settings = RAWSettings()
        settings.values = [.exposure: 2, .shadowBias: 2, .luminance: 0, .color: 0.3]
        let worker = RAWDeveloper(colorSpace: .displayP3, rawSettings: settings)
        let started = Date()
        let fitted = try await worker.maximumRAWRange(url)
        assert(fitted.values[.color] == settings.values[.color])
        assert(fitted.values[.luminance] == settings.values[.luminance])
        assert(fitted.lensCorrection == settings.lensCorrection)
        let exposure = fitted.values[.exposure]!, bias = fitted.values[.shadowBias]!
        assert((-5...5).contains(exposure) && bias == 0)
        let raw = CIRAWFilter(imageURL: url)!
        raw.baselineExposure = 0; fitted.apply(to: raw)
        raw.boostAmount = 0; raw.localToneMapAmount = 0; raw.isGamutMappingEnabled = false
        let source = raw.outputImage!
        let scale = min(1, 1024 / max(source.extent.width, source.extent.height))
        let sampled = source.samplingNearest().transformed(by: CGAffineTransform(scaleX:scale,y:scale))
        let width = Int(sampled.extent.width), height = Int(sampled.extent.height)
        let space = ProcessingColorSpace.displayP3.linear
        let context = CIContext(options:[.workingColorSpace:space,.workingFormat:CIFormat.RGBAf])
        var pixels = [Float](repeating:0,count:width*height*4)
        context.render(sampled,toBitmap:&pixels,rowBytes:width*16,bounds:CGRect(x:0,y:0,width:width,height:height),format:.RGBAf,colorSpace:space)
        let maximum = RAWSignalRange.highlight(pixels)!
        assert(maximum.isFinite)
        if exposure > -5 && exposure < 5 { assert(abs(maximum-1)<0.002, "Peak did not fit: \(maximum)") }
        print("Max Range: \(url.lastPathComponent), exposure \(exposure), bias \(bias), trimmed highlight \(maximum), \(Date().timeIntervalSince(started)) s. Other RAW settings retained.")
    }
}
