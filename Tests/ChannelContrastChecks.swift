import CoreImage
import Foundation
@testable import Dark_Melon

@main struct ChannelContrastChecks {
    static func main() async throws {
        var mapping = ToneMapping.fresh(isRAW: true, sourceHeadroom: 1)
        for hdr in [false, true] {
            let original = mapping.curve(hdr: hdr)
            assert(mapping.channelCurves(hdr: hdr).allSatisfy { $0.values == original.values })
        }
        for equal in [-0.2, 0.0, 0.2] {
            mapping.channelContrast = [equal,equal,equal]
            assert(mapping.dyeContrastOffsets == [0,0,0])
            for hdr in [false,true] {
                assert(mapping.channelCurves(hdr:hdr).allSatisfy { $0.values == mapping.curve(hdr:hdr).values })
            }
        }
        for contrast in [-1.0,-0.99,0,0.99,1] {
            mapping.concentration = contrast
            mapping.channelContrast = [0.2,-0.2,0.1]
            let offsets = mapping.dyeContrastOffsets
            assert(abs(offsets.reduce(0,+)) < 1e-12)
            assert(offsets.allSatisfy { (-0.8...0.8).contains($0) })
        }
        mapping.concentration = 0.2
        mapping.channelContrast = [0.1,-0.1,0]
        let offsets = mapping.dyeContrastOffsets
        mapping.channelContrast = [0.15,-0.05,0.05]
        assert(zip(offsets,mapping.dyeContrastOffsets).allSatisfy { abs($0-$1)<1e-12 })
        mapping.channelContrast = [0.12, -0.08, 0]
        for hdr in [false, true] {
            let curves = mapping.channelCurves(hdr: hdr)
            for curve in curves {
                assert(curve.values.allSatisfy { $0.isFinite })
                assert(zip(curve.values, curve.values.dropFirst()).allSatisfy { $0 <= $1 })
            }
        }
        let recipe = DevelopmentRecipe(colorSpace: .sRGB, mapping: mapping)
        let decoded = try DevelopmentRecipe.decode(recipe.encoded())
        assert(decoded.mapping.channelContrast == mapping.channelContrast)
        var json = try JSONSerialization.jsonObject(with: recipe.encoded()) as! [String: Any]
        var old = json["mapping"] as! [String: Any]
        old.removeValue(forKey: "channelContrast"); json["mapping"] = old
        let migrated = try DevelopmentRecipe.decode(JSONSerialization.data(withJSONObject: json))
        assert(migrated.mapping.channelContrast == [0,0,0])
        let pasted = SettingsPasteSelection(tone: false, whiteBalance: false, color: false, effects: true, raw: false)
            .applying(mapping, to: ToneMapping())
        assert(pasted.channelContrast == mapping.channelContrast)

        let space = ProcessingColorSpace.sRGB
        let worker = RAWDeveloper(colorSpace: space)
        let context = CIContext(options: [.workingColorSpace: space.linear, .workingFormat: CIFormat.RGBAf])
        for hdr in [false, true] {
            for input in [0.05, 0.25, 0.6, 0.95] {
                let image = CIImage(color: CIColor(red: input, green: input, blue: input, colorSpace: space.linear)!)
                    .cropped(to: CGRect(x:0,y:0,width:1,height:1))
                let output = try await worker.mappedImage(image, mapping: mapping, hdr: hdr)
                var pixel = [Float](repeating:0,count:4)
                context.render(output,toBitmap:&pixel,rowBytes:16,bounds:image.extent,format:.RGBAf,colorSpace:space.linear)
                let curves = mapping.channelCurves(hdr: hdr)
                for c in 0..<3 {
                    let h = log2(input / max(1e-6,mapping.tonePosition))
                    let base = 1 / (1 + exp(-h/2))
                    let layer = 1 / (1 + exp(-h*(1+mapping.dyeContrastOffsets[c])/2))
                    let exposed = input * exp2(8*(layer-base))
                    assert(abs(Double(pixel[c])-curves[c].value(at:exposed)) < 0.002)
                }
            }
        }
        print("Dye response common-offset invariance, zero-sum limits, identity, monotonicity, persistence, migration, paste, and SDR/HDR GPU parity passed.")
    }
}
