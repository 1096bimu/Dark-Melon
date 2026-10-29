import CoreImage
import Foundation
@testable import Dark_Melon

@main struct LUTHDRChecks {
    static func main() async throws {
        let space = ProcessingColorSpace.sRGB
        let context = CIContext(options: [.workingColorSpace: space.linear, .workingFormat: CIFormat.RGBAf])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LUTStore(directory: folder.appendingPathComponent("LUTs"))
        let file = folder.appendingPathComponent("warm.cube")
        var cube = "LUT_3D_SIZE 2\n"
        for b in 0...1 { for g in 0...1 { for r in 0...1 {
            cube += "\(0.02 + Double(r)*0.8) \(0.02 + Double(g)*0.6) \(0.02 + Double(b)*0.4)\n"
        } } }
        try cube.write(to: file, atomically: true, encoding: .utf8)
        let id = try store.importFile(file)
        let pipeline = LUTPipeline(store: store)
        var mapping = ToneMapping()
        mapping.lutStrength = 0.37
        let restored = try JSONDecoder().decode(ToneMapping.self, from: JSONEncoder().encode(mapping))
        precondition(restored.lutStrength == 0.37)
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(mapping)) as! [String: Any]
        legacy.removeValue(forKey: "lutAmount")
        let old = try JSONDecoder().decode(ToneMapping.self, from: JSONSerialization.data(withJSONObject: legacy))
        precondition(old.lutStrength == 1)

        func image(_ rgb: SIMD3<Double>, alpha: Double = 1) -> CIImage {
            CIImage(color: CIColor(red: rgb.x, green: rgb.y, blue: rgb.z, alpha: alpha, colorSpace: space.linear)!)
                .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        func pixel(_ image: CIImage) -> [Double] {
            var rgba = [Float](repeating: 0, count: 4)
            context.render(image, toBitmap: &rgba, rowBytes: 16, bounds: CGRect(x: 20, y: 20, width: 1, height: 1),
                           format: .RGBAf, colorSpace: space.linear)
            return rgba.map(Double.init)
        }
        let input = image(SIMD3(0.2, 0.4, 0.6))
        let before = pixel(input)
        let full = pixel(try pipeline.apply(input, id: id))
        let half = pixel(try pipeline.apply(input, id: id, strength: 0.5))
        let zero = pixel(try pipeline.apply(input, id: id, strength: 0))
        for channel in 0..<4 {
            precondition(abs(zero[channel] - before[channel]) < 0.0001)
            precondition(abs(half[channel] - (before[channel] + full[channel]) * 0.5) < 0.0001)
        }

        func check(_ actual: [Double], _ expected: [Double], tolerance: Double = 0.0001) {
            assert(zip(actual, expected).allSatisfy { abs($0-$1) < tolerance }, "\(actual) != \(expected)")
        }
        let epsilon = 0.00001
        func reference(_ hdr: [Double], _ sdr: [Double], _ graded: [Double]) -> [Double] {
            (0..<3).map { max(0, (graded[$0]+epsilon)*(max(hdr[$0],0)+epsilon)/(min(1,max(sdr[$0],0))+epsilon)-epsilon) } + [hdr[3]]
        }
        for (s, h) in [(SIMD3(0.4,0.2,0.1), SIMD3(1.6,0.3,0.4)),
                       (SIMD3(1.0,1.0,1.0), SIMD3(4.0,2.0,1.5)),
                       (SIMD3(2.0,1.1,0.5), SIMD3(4.0,2.0,1.5)),
                       (SIMD3(0.0,0.0,0.0), SIMD3(0.0,0.0,0.0))] {
            let sdr = image(s), hdr = image(h)
            let graded = try pipeline.apply(sdr, id: id)
            let result = try pipeline.applyHDR(hdr, sdr: sdr, gradedSDR: graded)
            check(pixel(result), reference(pixel(hdr), pixel(sdr), pixel(graded)), tolerance: 0.0005)
            check(pixel(try pipeline.applyHDR(hdr, sdr: sdr, gradedSDR: image(SIMD3(min(1,s.x),min(1,s.y),min(1,s.z))))), pixel(hdr))
        }
        // The LUT's white-point tint scales, rather than flattens, colored HDR highlights.
        let white = image(SIMD3(repeating: 1)), bright = image(SIMD3(4,2,1.5))
        let gradedWhite = try pipeline.apply(white, id: id)
        let gradedBright = pixel(try pipeline.applyHDR(bright, sdr: white, gradedSDR: gradedWhite))
        assert(gradedBright[0] > pixel(gradedWhite)[0]*3.9)
        // Alpha is preserved, and reconstruction is continuous across SDR white.
        var previous: [Double]?
        for level in [0.9999, 1.0, 1.0001] {
            let s = image(SIMD3(repeating:min(1,level))), h = image(SIMD3(repeating:level),alpha:0.5)
            let result = pixel(try pipeline.applyHDR(h, sdr:s, gradedSDR:pipeline.apply(s,id:id)))
            assert(abs(result[3]-0.5)<0.00001)
            if let previous { assert(zip(result,previous).allSatisfy { abs($0-$1)<0.001 }) }
            previous = result
        }
        let worker = RAWDeveloper(colorSpace:space,lutStore:store)
        let source = image(SIMD3(0.7,0.4,0.2))
        var original = ToneMapping(); original.white = 0.3; original.hdrGain = 1.01
        var gradedMapping = original; gradedMapping.lutID = id
        let sdr = try await worker.mappedImage(source,mapping:original,hdr:false)
        let hdr = try await worker.mappedImage(source,mapping:original,hdr:true)
        let gradedSDR = try await worker.mappedImage(source,mapping:gradedMapping,hdr:false)
        let gradedHDR = try await worker.mappedImage(source,mapping:gradedMapping,hdr:true)
        check(pixel(gradedHDR),reference(pixel(hdr),pixel(sdr),pixel(gradedSDR)),tolerance:0.001)
        let bitmap = context.createCGImage(source,from:source.extent,format:.RGBAf,colorSpace:space.linear)!
        let preview = try await worker.previews(bitmap,mapping:gradedMapping)
        check(pixel(CIImage(cgImage:preview.hdr)),pixel(gradedHDR),tolerance:0.003)
        check(pixel(CIImage(cgImage:preview.fullHDR)),pixel(gradedHDR),tolerance:0.003)
        gradedMapping.lutID = UUID()
        let missing = try await worker.mappedImage(source,mapping:gradedMapping,hdr:true)
        check(pixel(missing),pixel(hdr))
        print("Per-channel HDR gain preservation, colored clipped highlights, identity, black, alpha, white-boundary continuity, preview/export parity and missing-LUT bypass passed.")
    }
}
