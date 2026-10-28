import Foundation
import CoreImage
import ImageIO
@testable import Dark_Melon

@main struct VariationExportChecks {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for n in 2...8 {
            let plan = VariationExport(grid: n, strength: 3)
            var covered = Set<Int>()
            for i in plan.generations.indices {
                let r = plan.tile(i, width: 131, height: 99)
                for y in Int(r.minY)..<Int(r.maxY) { for x in Int(r.minX)..<Int(r.maxX) {
                    precondition(covered.insert(y*131+x).inserted)
                } }
            }
            precondition(covered.count == 131*99)
            precondition(Set(plan.generations.map(\.seed)).count == n*n)
        }
        let example = VariationExport(grid: 2, strength: 1)
        precondition(example.tile(0, width: 3000, height: 2000).size == CGSize(width: 1500,height: 1000))
        let space = ProcessingColorSpace.sRGB
        let context = CIContext(options: [.workingColorSpace: space.linear, .workingFormat: CIFormat.RGBAf])
        let bounds = CGRect(x: 0,y: 0,width: 128,height: 96)
        let background = CIImage(color: CIColor(red: 0.03,green: 0.2,blue: 0.4)).cropped(to: bounds)
        let top = CIImage(color: CIColor(red: 0.3,green: 0.05,blue: 0.1)).cropped(to: CGRect(x: 0,y: 48,width: 128,height: 48))
        let image = top.composited(over: background)
        let url = directory.appendingPathComponent("source.png")
        try context.writePNGRepresentation(of: image,to: url,format: .RGBA16,colorSpace: space.encoded)
        let worker = RAWDeveloper(colorSpace: space, exporting: true)
        var mapping = ToneMapping()
        mapping.channelContrast = [0.12,-0.07,-0.05]
        mapping.hdrGain = 3
        let plan = VariationExport(grid: 2,strength: 2)
        func sample(_ image: CIImage, x: Int, y: Int) -> [Float] {
            var pixel = [Float](repeating:0,count:4)
            context.render(image,toBitmap:&pixel,rowBytes:16,bounds:CGRect(x:x,y:y,width:1,height:1),format:.RGBAf,colorSpace:space.linear)
            return pixel
        }
        for format in ExportFormat.allCases {
            var settings = HEIFSettings()
            settings.format = format; settings.scale = 0.5; settings.quality = 1
            settings.jpegHDR = true; settings.heifHDRMode = .direct; settings.tiffHDR = true
            let data = try await worker.variationExport(url,mapping:mapping,settings:settings,variation:plan)
            let container = CGImageSourceCreateWithData(data as CFData,nil)!
            let bitmap = CGImageSourceCreateImageAtIndex(container,0,nil)!
            precondition(bitmap.width == 64 && bitmap.height == 48)
            precondition(CGImageSourceCopyAuxiliaryDataInfoAtIndex(container,0,kCGImageAuxiliaryDataTypeHDRGainMap) == nil)
            precondition(CGImageSourceCopyAuxiliaryDataInfoAtIndex(container,0,kCGImageAuxiliaryDataTypeISOGainMap) == nil)
            let decoded = CIImage(cgImage:bitmap)
            var colors = [[Float]]()
            for i in 0..<4 {
                let rect = plan.tile(i,width:64,height:48)
                let pixel = sample(decoded,x:Int(rect.minX)+8,y:Int(rect.minY)+18)
                colors.append(pixel)
                if format == .tiff {
                    var expectedMapping = mapping
                    expectedMapping.dyeMixers = DyeMixers.seeded(plan.generations[i])!
                    let expected = try await worker.mappedImage(CIImage(contentsOf:url)!,mapping:expectedMapping,hdr:false)
                    let reference = sample(expected,x:32,y:72)
                    precondition(zip(pixel,reference).allSatisfy { abs($0-$1)<0.002 }, "Tile layout or rendering mismatch: \(pixel) vs \(reference)")
                }
            }
            precondition(colors.dropFirst().contains { zip($0,colors[0]).contains { abs($0-$1)>0.001 } })
            print("PASS: \(format) dimensions, independent Brews, SDR-only output")
        }
        print("PASS: grids 2–8 cover every pixel; TIFF tiles match their frozen recipes")
    }
}
