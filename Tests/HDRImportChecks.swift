import Foundation
import CoreImage
@testable import Dark_Melon

@main struct HDRImportChecks {
    static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.8))
            .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 48))
        var original = ToneMapping(); original.concentration = 0; original.hdrGain = 8; original.setAutomaticHDRTarget()
        let encoder = RAWDeveloper(colorSpace: .displayP3)
        let context = CIContext(options: [.workingColorSpace: ProcessingColorSpace.displayP3.linear, .workingFormat: CIFormat.RGBAf])
        func sample(_ image: CIImage) -> [Float] {
            var pixels = [Float](repeating: 0, count: 4)
            context.render(image, toBitmap: &pixels, rowBytes: 16, bounds: CGRect(x: 32, y: 24, width: 1, height: 1),
                           format: .RGBAf, colorSpace: ProcessingColorSpace.displayP3.linear)
            return pixels
        }
        for mode in ["HEIF gain map", "JPEG gain map", "PQ"] {
            var settings = HEIFSettings()
            settings.format = mode == "JPEG gain map" ? .jpeg : .heif
            settings.jpegHDR = true
            settings.heifHDRMode = mode == "PQ" ? .direct : .gainMap
            let bytes = try await encoder.exportImage(source, mapping: original, settings: settings)
            let url = folder.appendingPathComponent(mode + "." + settings.format.fileExtension)
            try bytes.write(to: url)
            let decoded = CIImage(contentsOf: url, options: [.expandToHDR: true, .toneMapHDRtoSDR: false])!
            let worker = RAWDeveloper(colorSpace: .displayP3)
            let development = try await worker.develop(url)
            let mapping = ToneMapping.fresh(isRAW: false, sourceHeadroom: development.sourceHeadroom)
            assert(mapping.hdrGain > 5)
            let restored = try await worker.mappedImage(development.linearSource, mapping: mapping, hdr: true)
            let expected = sample(decoded), actual = sample(restored)
            for index in 0..<3 { assert(abs(expected[index] - actual[index]) < 0.005, "\(mode): \(expected) vs \(actual)") }
            let prepared = try await BrowserRecipeTarget.load(url)
            assert(prepared.recipe.mapping == mapping)
            print("PASS: \(mode) imported HDR appearance and batch defaults preserved at \(mapping.hdrGain)x")
        }
    }
}
