import Foundation
import CoreImage
@testable import Dark_Melon

@main struct RetiredShadowFloorChecks {
    static func main() async throws {
        let original = DevelopmentRecipe(colorSpace: .sRGB, mapping: ToneMapping())
        var legacy = try JSONSerialization.jsonObject(with: original.encoded()) as! [String: Any]
        var edits = legacy["mapping"] as! [String: Any]
        edits["storedShadowFloorCode"] = 255
        edits["storedShadowFloor"] = 0.5
        legacy["mapping"] = edits
        let restored = try DevelopmentRecipe.decode(JSONSerialization.data(withJSONObject: legacy))
        precondition(restored == original)
        let saved = try JSONSerialization.jsonObject(with: restored.encoded()) as! [String: Any]
        let mapping = saved["mapping"] as! [String: Any]
        precondition(mapping["storedShadowFloorCode"] == nil && mapping["storedShadowFloor"] == nil)
        let selection = try JSONDecoder().decode(SettingsPasteSelection.self, from: Data("{\"items\":[\"shadowFloor\",\"tone\"]}".utf8))
        precondition(selection.selectedItems == [.tone])
        let space = ProcessingColorSpace.sRGB
        let context = CIContext(options: [.workingColorSpace: space.linear, .workingFormat: CIFormat.RGBAf])
        let bounds = CGRect(x: 0, y: 0, width: 8, height: 8)
        let black = CIImage(color: .black).cropped(to: bounds)
        let source = context.createCGImage(black, from: bounds, format: .RGBAh, colorSpace: space.linear)!
        func check(_ image: CIImage) {
            var rgba = [Float](repeating: 0, count: 8*8*4)
            context.render(image, toBitmap: &rgba, rowBytes: 8*16, bounds: bounds, format: .RGBAf, colorSpace: space.linear)
            precondition(stride(from: 0, to: rgba.count, by: 4).allSatisfy { rgba[$0] == 0 && rgba[$0+1] == 0 && rgba[$0+2] == 0 })
        }
        for interactive in [false, true] {
            let worker = RAWDeveloper(colorSpace: space, interactive: interactive)
            let preview = try await worker.previews(source, mapping: restored.mapping)
            check(CIImage(cgImage: preview.sdr)); check(CIImage(cgImage: preview.hdr))
        }
        let worker = RAWDeveloper(colorSpace: space)
        var settings = HEIFSettings(); settings.format = .tiff; settings.tiff16Bit = true; settings.tiffHDR = false
        let data = try await worker.exportImage(black, mapping: restored.mapping, settings: settings)
        check(CIImage(data: data)!)
        print("PASS: retired floor keys and selections discarded; SDR/HDR previews and TIFF retain black")
    }
}
