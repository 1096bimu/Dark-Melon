import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import Dark_Melon

@main struct PresetConfirmationChecks {
    @MainActor static func main() async throws {
        var original = DevelopmentRecipe(colorSpace: .displayP3, mapping: ToneMapping())
        original.mapping.concentration = 0.3
        original.mapping.hdf = 0.05
        var raw = RAWSettings()
        raw.values = [.exposure:0,.luminance:0.2]
        original.rawSettings = raw
        var source = original
        source.mapping.concentration = 0.7
        source.mapping.hdf = 0.1
        source.rawSettings!.values = [.exposure:2,.luminance:0.8]
        let selection = SettingsPasteSelection(items:[.contrast,.exposure])
        let preset = PresetApplication(name:"Test",recipe:source,selection:selection)
        let preview = preset.applying(to:original,isRAW:true)
        assert(preview.mapping.concentration == 0.7)
        assert(preview.mapping.hdf == 0.05)
        assert(preview.rawSettings!.values[.exposure] == 2)
        assert(preview.rawSettings!.values[.luminance] == 0.2)
        assert(original.mapping.concentration == 0.3 && original.rawSettings!.values[.exposure] == 0)
        assert(Set(preset.replacements(isRAW:true)) == [.contrast,.exposure])
        assert(preset.replacements(isRAW:false) == [.contrast])
        let nonRAW = preset.applying(to:original,isRAW:false)
        assert(nonRAW.rawSettings == original.rawSettings)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at:file) }
        let context = CIContext()
        let input = CIImage(color:CIColor(red:0.35,green:0.35,blue:0.35,colorSpace:ProcessingColorSpace.sRGB.linear)!)
            .cropped(to:CGRect(x:0,y:0,width:64,height:64))
        let bitmap = context.createCGImage(input,from:input.extent,format:.RGBA8,colorSpace:ProcessingColorSpace.sRGB.encoded)!
        let destination = CGImageDestinationCreateWithURL(file as CFURL,UTType.png.identifier as CFString,1,nil)!
        CGImageDestinationAddImage(destination,bitmap,nil)
        assert(CGImageDestinationFinalize(destination))
        let worker = RAWDeveloper(colorSpace:.sRGB)
        let development = try await worker.develop(file,previewCanvas:CGSize(width:128,height:128))
        var baseline = DevelopmentRecipe(colorSpace:.sRGB,mapping:ToneMapping())
        baseline.mapping.hdrGain = 0
        var treatment = baseline
        treatment.mapping.concentration = 0.8
        let candidate = PresetApplication(name:"Contrast",recipe:treatment,selection:SettingsPasteSelection(items:[.contrast]))
        let result = try await PresetPreview.prepare(candidate,original:baseline,development:development,
            canvas:CGSize(width:128,height:128),cachedBefore:nil)
        assert(result.id == candidate.id && result.recipe.mapping.concentration == 0.8)
        assert(result.development.id == development.id) // No decoder change: retain the source.
        assert(baseline.mapping.concentration == 0.2)
        func sample(_ image: CGImage) -> Float {
            var pixel = [Float](repeating:0,count:4)
            context.render(CIImage(cgImage:image),toBitmap:&pixel,rowBytes:16,bounds:CGRect(x:32,y:32,width:1,height:1),format:.RGBAf,colorSpace:ProcessingColorSpace.sRGB.linear)
            return pixel[0]
        }
        assert(abs(sample(result.before.sdr)-sample(result.after.sdr))>0.01)
        let cached = try await PresetPreview.prepare(candidate,original:baseline,development:development,
            canvas:CGSize(width:128,height:128),cachedBefore:result.before)
        assert(cached.before.sdr === result.before.sdr)
        print("Preset preview isolation, before/after rendering, cached-before reuse, selected replacements and RAW merge passed.")
    }
}
