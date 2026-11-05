import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import Dark_Melon

@main struct ShadowFloorChecks {
    @MainActor static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let lutFile = folder.appendingPathComponent("Black.cube")
        try ("LUT_3D_SIZE 2\n" + String(repeating: "0 0 0\n", count: 8)).write(to: lutFile, atomically: true, encoding: .utf8)
        let store = LUTStore(directory: folder.appendingPathComponent("LUTs"))
        let lut = try store.importFile(lutFile)
        for space in ProcessingColorSpace.allCases {
            let context = CIContext(options: [.workingColorSpace: space.linear, .workingFormat: CIFormat.RGBAf])
            let extent = CGRect(x: 0, y: 0, width: 8, height: 8)
            let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent)
            let source = context.createCGImage(black, from: extent, format: .RGBAh, colorSpace: space.linear)!
            func bytes(_ image: CGImage) -> [UInt8] {
                var output = [UInt8](repeating: 0, count: 8 * 8 * 4)
                context.render(CIImage(cgImage: image), toBitmap: &output, rowBytes: 8 * 4,
                    bounds: extent, format: .RGBA8, colorSpace: space.encoded)
                return output
            }
            func check(_ image: CGImage, code: Int) {
                let rgba = bytes(image)
                for i in stride(from: 0, to: rgba.count, by: 4) {
                    precondition(rgba[i + 3] == 255)
                    for channel in 0..<3 {
                        precondition(Int(rgba[i + channel]) == code,
                            "Wrong output floor in \(space): \(rgba[i + channel]) != \(code)")
                    }
                }
            }
            let worker = RAWDeveloper(colorSpace: space, lutStore: store)
            let interactive = RAWDeveloper(colorSpace: space, lutStore: store, interactive: true)
            for floor in [1, 10, 64, 128, 255] {
                for contrast in [-0.5, 0.0, 0.7] {
                    var mapping = ToneMapping.fresh(isRAW: false, sourceHeadroom: 1)
                    mapping.white = contrast == 0 ? 1 : 0.3
                    mapping.concentration = contrast
                    mapping.shadowFloor = Double(floor)
                    check(try await worker.preview(source, mapping: mapping, hdr: false), code: floor)
                    let previews = try await interactive.previews(source, mapping: mapping)
                    check(previews.sdr, code: floor)
                    check(previews.fullSDR, code: floor)
                }
            }
            var mapping = ToneMapping.fresh(isRAW: false, sourceHeadroom: 1)
            mapping.shadowFloor = 10
            mapping.lutID = lut
            check(try await worker.preview(source, mapping: mapping, hdr: false), code: 10)
            check(try await interactive.previews(source, mapping: mapping).sdr, code: 10)
            let development = RAWDevelopment(preview: source, linearSource: black, url: folder.appendingPathComponent("source.png"),
                width: 8, height: 8, whitePoint: nil, metadata: CameraMetadata(properties: [:]), isRAW: false,
                rawDefaults: nil, sourceHeadroom: 1)
            let detail = try await interactive.detail(development, mapping: mapping, hdr: false,
                region: PreviewRegion(rect: CGRect(x: 0, y: 0, width: 1, height: 1), displayPixels: extent.size))
            check(detail.image, code: 10)
            let reference = try await worker.referenceImages(development, mapping: mapping)
            check(reference.sdr, code: 10)
            var settings = HEIFSettings()
            settings.format = .tiff; settings.tiffHDR = false; settings.tiff16Bit = false
            let data = try await worker.exportImage(black, mapping: mapping, settings: settings)
            let encoded = CGImageSourceCreateWithData(data as CFData, nil)!
            check(CGImageSourceCreateImageAtIndex(encoded, 0, nil)!, code: 10)
            let destination = CGImageDestinationCreateWithURL(development.url as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, source, nil)
            precondition(CGImageDestinationFinalize(destination))
            let cached = try await worker.cachedExport(development.url, mapping: mapping, settings: settings)
            check(CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(cached as CFData, nil)!, 0, nil)!, code: 10)
            let restored = try DevelopmentRecipe.decode(DevelopmentRecipe(colorSpace: space, mapping: mapping).encoded())
            precondition(restored.mapping.shadowFloor == 10)
            precondition(SettingsPasteSelection(items: [.shadowFloor]).applying(mapping, to: ToneMapping()).shadowFloor == 10)
            var legacy = try JSONSerialization.jsonObject(with: DevelopmentRecipe(colorSpace: space, mapping: mapping).encoded()) as! [String: Any]
            var old = legacy["mapping"] as! [String: Any]
            old.removeValue(forKey: "storedShadowFloorCode")
            old["storedShadowFloor"] = 0.04
            legacy["mapping"] = old
            let migrated = try DevelopmentRecipe.decode(JSONSerialization.data(withJSONObject: legacy))
            let expected = space.sdrCode(forLinear: mapping.curve(hdr: false).value(at: 0.04))
            precondition(abs(migrated.mapping.shadowFloor - expected) < 1e-8)
            let persisted = try JSONSerialization.jsonObject(with: migrated.encoded()) as! [String: Any]
            precondition((persisted["mapping"] as! [String: Any])["storedShadowFloor"] == nil)
            for bad in [-1.0, 255.1] {
                var invalid = mapping; invalid.shadowFloor = bad
                do { _ = try DevelopmentRecipe.decode(DevelopmentRecipe(colorSpace: space, mapping: invalid).encoded()); preconditionFailure("Invalid code accepted") }
                catch RecipeError.invalid { }
            }
        }
        print("PASS: output codes 1/10/64/128/255, three SDR spaces, tone independence, final LUT clamp, overview/detail/reference, TIFF/cached export, persistence/paste and legacy migration")
    }
}
