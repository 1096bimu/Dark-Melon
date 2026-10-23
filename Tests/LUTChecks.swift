import CoreImage
import Foundation
@testable import Dark_Melon

@main struct LUTChecks {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let store = LUTStore(directory:directory.appendingPathComponent("LUTs"))
        func text(invert:Bool,domain:String="") -> String {
            var result = "# test\nTITLE \"Example\"\nLUT_3D_SIZE 2\n" + domain
            for b in 0...1 { for g in 0...1 { for r in 0...1 {
                result += "\(invert ? 1-r:r) \(invert ? 1-g:g) \(invert ? 1-b:b)\n"
            } } }
            return result
        }
        let file = directory.appendingPathComponent("Example.cube")
        try text(invert:true).write(to:file,atomically:true,encoding:.utf8)
        let id = try store.importFile(file)
        let second = try store.importFile(file)
        assert(id != second)
        try FileManager.default.removeItem(at:file)
        assert(store.cube(for:id) != nil && FileManager.default.fileExists(atPath:store.url(for:id).path))
        let pipeline = LUTPipeline(store:store)
        let space = ProcessingColorSpace.sRGB
        let context = CIContext(options:[.workingColorSpace:space.linear,.workingFormat:CIFormat.RGBAf])
        func image(_ rgb: SIMD3<Double>, alpha:Double=1) -> CIImage {
            CIImage(color:CIColor(red:rgb.x,green:rgb.y,blue:rgb.z,alpha:alpha,colorSpace:space.linear)!)
                .cropped(to:CGRect(x:0,y:0,width:4,height:4))
        }
        func pixel(_ image:CIImage) -> [Double] {
            var rgba = [Float](repeating:0,count:4)
            context.render(image,toBitmap:&rgba,rowBytes:16,bounds:CGRect(x:1,y:1,width:1,height:1),format:.RGBAf,colorSpace:space.linear)
            return rgba.map(Double.init)
        }
        func check(_ actual:[Double],_ expected:[Double]) {
            assert(zip(actual,expected).allSatisfy { abs($0-$1)<0.003 }, "\(actual) != \(expected)")
        }
        func inverted(_ linear:Double) -> Double {
            let encoded = linear <= 0.0031308 ? linear * 12.92 : 1.055 * pow(linear,1 / 2.4) - 0.055
            let output = 1 - encoded
            return output <= 0.04045 ? output / 12.92 : pow((output + 0.055) / 1.055,2.4)
        }
        check(pixel(try pipeline.apply(image(SIMD3(0.2,0.4,0.6)),id:id)),[inverted(0.2),inverted(0.4),inverted(0.6),1])
        check(pixel(try pipeline.apply(image(SIMD3(2,1.5,0.5)),id:id)),[0,0,inverted(0.5),1])
        check(pixel(try pipeline.apply(image(SIMD3(0.2,0.4,0.6),alpha:0.5),id:id)),[inverted(0.2)*0.5,inverted(0.4)*0.5,inverted(0.6)*0.5,0.5])
        let untouched = image(SIMD3(0.2,0.4,0.6))
        let missing = try pipeline.apply(untouched,id:UUID())
        assert(missing === untouched)
        var mapping = ToneMapping()
        mapping.lutID = id
        mapping.concentration = 0; mapping.hdrGain = 0
        mapping.whiteBalance.red = 2
        let worker = RAWDeveloper(colorSpace:space,lutStore:store)
        let rendered = try await worker.mappedImage(untouched,mapping:mapping,hdr:false)
        check(pixel(rendered),[inverted(0.4),inverted(0.4),inverted(0.6),1]) // LUT after RGB white balance.
        let recipe = DevelopmentRecipe(colorSpace:space,mapping:mapping)
        let decoded = try DevelopmentRecipe.decode(recipe.encoded())
        assert(decoded.mapping.lutID == id)
        assert(SettingsPasteSelection(items:[.lut]).applying(mapping,to:ToneMapping()).lutID == id)
        let entry = LibraryEntry(name:"Example",lutID:id)
        let entryData = try JSONEncoder().encode(entry)
        let restoredEntry = try JSONDecoder().decode(LibraryEntry.self,from:entryData)
        assert(!restoredEntry.isFolder && restoredEntry.lutID == id)
        store.remove(id)
        let removed = try pipeline.apply(untouched,id:id)
        assert(removed === untouched)
        let ignored = try await worker.mappedImage(untouched,mapping:mapping,hdr:false)
        check(pixel(ignored),[0.4,0.4,0.6,1])
        try text(invert:false,domain:"DOMAIN_MIN 0 0 0\nDOMAIN_MAX 2 2 2\n").write(to:file,atomically:true,encoding:.utf8)
        let domainID = try store.importFile(file)
        check(pixel(try pipeline.apply(image(SIMD3(2,0.5,1)),id:domainID)),[0.5,0.25,0.5,1])
        for broken in ["LUT_1D_SIZE 2\n0 0 0\n1 1 1", "LUT_3D_SIZE 2\n0 0 0", "LUT_3D_SIZE 999999"] {
            do { _ = try LUTCube(data:Data(broken.utf8)); assertionFailure("Accepted invalid LUT") } catch {}
        }
        print("LUT import/copy/UUIDs, RGB ordering, interpolation, HDR clamp, alpha, final-stage rendering, missing assets, recipe/paste and domain validation passed.")
    }
}
