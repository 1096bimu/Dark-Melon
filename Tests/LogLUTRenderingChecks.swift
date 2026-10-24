import CoreImage
import Foundation
import ImageIO
@testable import Dark_Melon

@main struct LogLUTRenderingChecks {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LUTStore(directory: root.appendingPathComponent("LUTs"))
        let file = root.appendingPathComponent("identity.cube")
        var cube = "LUT_3D_SIZE 2\n"
        for b in 0...1 { for g in 0...1 { for r in 0...1 { cube += "\(r) \(g) \(b)\n" } } }
        try cube.write(to: file, atomically: true, encoding: .utf8)
        let id = try store.importFile(file)
        let space = ProcessingColorSpace.displayP3
        let context = CIContext(options: [.workingColorSpace: space.linear, .workingFormat: CIFormat.RGBAf])
        let source = CIImage(color: CIColor(red: 0.5,green: 0.45,blue: 0.35,colorSpace: space.linear)!)
            .cropped(to: CGRect(x: 0,y: 0,width: 64,height: 48))
        func pixel(_ image: CIImage) -> SIMD4<Float> {
            var value = SIMD4<Float>(repeating: 0)
            context.render(image,toBitmap: &value,rowBytes: 16,bounds: CGRect(x: 32,y: 24,width: 1,height: 1),format: .RGBAf,colorSpace: space.linear)
            return value
        }
        func near(_ a: SIMD4<Float>, _ b: SIMD4<Float>, tolerance: Float = 0.0005) {
            assert((0..<4).allSatisfy { abs(a[$0]-b[$0]) < tolerance }, "\(a) != \(b)")
        }
        let worker = RAWDeveloper(colorSpace: space,lutStore: store)
        var mapping = ToneMapping(); mapping.concentration = 0; mapping.hdrGain = 8; mapping.setAutomaticHDRTarget()
        mapping.clarity = 0.2; mapping.hdf = 0.02; mapping.whiteBalance.red = 1.1
        let bitmap = context.createCGImage(source,from: source.extent,format: .RGBAf,colorSpace: space.linear)!
        for profile in [LUTProfile.sLog3,.vLog,.cLog3] {
            try store.configure(id,as: LUTConfiguration(input: profile,output: .sRGB))
            let hdr = try await worker.mappedImage(source,mapping: mapping,hdr: true)
            assert(pixel(hdr).x > 1)
            let expected = try LUTPipeline(store: store).apply(hdr,id: id)
            var graded = mapping; graded.lutID = id
            let sdr = try await worker.mappedImage(source,mapping: graded,hdr: false)
            let alternate = try await worker.mappedImage(source,mapping: graded,hdr: true)
            near(pixel(sdr),pixel(expected)); near(pixel(alternate),pixel(expected))
            let preview = try await worker.previews(bitmap,mapping: graded)
            near(pixel(CIImage(cgImage: preview.sdr)),pixel(expected),tolerance: 0.006)
            near(pixel(CIImage(cgImage: preview.hdr)),pixel(expected),tolerance: 0.006)
            assert(CIImage(cgImage: preview.hdr).contentHeadroom == 1)
            var off = graded; off.hdrGain = 0
            var unselected = off; unselected.lutID = nil
            for mode in [false,true] {
                let actual = try await worker.mappedImage(source,mapping: off,hdr: mode)
                let bypass = try await worker.mappedImage(source,mapping: unselected,hdr: mode)
                near(pixel(actual),pixel(bypass),tolerance: 0.000001)
            }
            print("PASS: \(profile) receives full developed HDR, SDR/HDR previews agree, HDR-off bypass")
        }
        try store.configure(id,as: LUTConfiguration(input: .vLog,output: .sRGB))
        mapping.lutID = id
        let inputFile = root.appendingPathComponent("source.png")
        try context.writePNGRepresentation(of: source,to: inputFile,format: .RGBA16,colorSpace: space.encoded)
        let inputImage = CIImage(contentsOf: inputFile)!
        let expected = try await worker.mappedImage(inputImage,mapping: mapping,hdr: false)
        for format in ExportFormat.allCases {
            for direct in [false,true] {
                var settings = HEIFSettings(); settings.format = format; settings.quality = 1
                settings.jpegHDR = true; settings.tiffHDR = true; settings.heifHDRMode = direct ? .direct : .gainMap
                let cached = try await worker.cachedExport(inputFile,mapping: mapping,settings: settings)
                let directBytes = try await worker.exportHEIF(inputFile,mapping: mapping,settings: settings)
                for data in [cached,directBytes] {
                    let image = CIImage(data: data,options: [.expandToHDR: true])!
                    assert(image.contentHeadroom == 1)
                    near(pixel(image),pixel(expected),tolerance: 0.02)
                    let container = CGImageSourceCreateWithData(data as CFData,nil)!
                    assert(CGImageSourceCopyAuxiliaryDataInfoAtIndex(container,0,kCGImageAuxiliaryDataTypeISOGainMap) == nil)
                }
            }
            print("PASS: \(format) cached and batch encoding remain SDR even with HDR export options selected")
        }
        let development = try await worker.develop(inputFile)
        let region = PreviewRegion(rect: CGRect(x: 0,y: 0,width: 1,height: 1),displayPixels: CGSize(width: 64,height: 48))
        let detail = try await worker.detail(development,mapping: mapping,hdr: true,region: region)
        near(pixel(CIImage(cgImage: detail.image)),pixel(expected),tolerance: 0.006)
        print("PASS: viewport detail matches full-frame SDR output")
        if CommandLine.arguments.count > 1 {
            let actualID = try store.importFile(URL(fileURLWithPath: CommandLine.arguments[1]))
            try store.configure(actualID,as: LUTConfiguration(input: .vLog,output: .sRGB))
            var look = ToneMapping(); look.concentration = 0; look.hdrGain = 8; look.setAutomaticHDRTarget(); look.lutID = actualID
            let grey = CIImage(color: CIColor(red: 0.5,green: 0.5,blue: 0.5,colorSpace: space.linear)!).cropped(to: source.extent)
            let result = try await worker.mappedImage(grey,mapping: look,hdr: false)
            var bytes = [UInt8](repeating: 0,count: 4)
            context.render(result,toBitmap: &bytes,rowBytes: 4,bounds: CGRect(x: 32,y: 24,width: 1,height: 1),format: .RGBA8,colorSpace: ProcessingColorSpace.sRGB.encoded)
            assert(bytes.prefix(3).allSatisfy { (240...244).contains(Int($0)) })
            print("PASS: provided Leica Standard LUT receives linear 4 and produces SDR RGB \(bytes.prefix(3))")
        }

    }
}
