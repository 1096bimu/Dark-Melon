import CoreImage
import Foundation
import simd
@testable import Dark_Melon

@main struct LUTProfileChecks {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LUTStore(directory: root.appendingPathComponent("store"))
        let source = root.appendingPathComponent("identity.cube")
        let dimension = 33
        var text = "LUT_3D_SIZE \(dimension)\n"
        for b in 0..<dimension { for g in 0..<dimension { for r in 0..<dimension {
            text += "\(Double(r)/32) \(Double(g)/32) \(Double(b)/32)\n"
        } } }
        try Data(text.utf8).write(to: source)
        let id = try store.importFile(source)
        assert(store.configuration(for: id) == LUTConfiguration())
        let context = CIContext(options: [.workingColorSpace: ProcessingColorSpace.sRGB.linear, .workingFormat: CIFormat.RGBAf])
        let transform = LUTProfileTransform()
        func sample(_ image: CIImage, space: CGColorSpace = ProcessingColorSpace.sRGB.linear) -> SIMD4<Float> {
            var pixel = SIMD4<Float>(repeating: 0)
            context.render(image, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: space)
            return pixel
        }
        func image(_ value: SIMD4<Float>, space: CGColorSpace = ProcessingColorSpace.sRGB.linear) -> CIImage {
            var value = value
            return withUnsafeBytes(of: &value) { CIImage(bitmapData: Data($0), bytesPerRow: 16, size: CGSize(width: 1, height: 1), format: .RGBAf, colorSpace: space) }
        }
        func near(_ a: SIMD4<Float>, _ b: SIMD4<Float>, tolerance: Float = 0.0002) {
            assert((0..<4).allSatisfy { abs(a[$0] - b[$0]) < tolerance }, "\(a) != \(b)")
        }
        let reference: [LUTProfile: Float] = [.sRGB: 0.46135613, .rec709: 0.40900773,
            .sLog3: 420.0/1023.0, .vLog: 0.42331145, .cLog3: 0.34338962, .fLog: 0.45931846, .fLog2: 0.39100724]
        for profile in LUTProfile.allCases {
            let grey = image(.init(0.18, 0.18, 0.18, 1))
            let encoded = try transform.encode(grey, profile: profile)
            let pixel = sample(encoded)
            assert(abs(pixel.x - reference[profile]!) < 0.0001, "\(profile): \(pixel)")
            near(sample(try transform.decode(encoded, profile: profile)), sample(grey))
            let config = LUTConfiguration(input: profile, output: profile)
            try store.configure(id, as: config)
            let pipeline = LUTPipeline(store: store)
            for rgb in [SIMD4<Float>(0,0,0,1), .init(0.1,0.3,0.7,1), .init(0.8,0.5,0.2,1), .init(0.2,0.1,0.15,0.5)] {
                let input = image(rgb)
                let direct = sample(try transform.decode(transform.encode(input, profile: profile), profile: profile))
                near(direct,sample(input),tolerance:0.0005)
                near(sample(try pipeline.apply(input, id: id)), sample(input), tolerance: profile == .sRGB ? 0.002 : 0.0005)
            }
            let reopened = LUTStore(directory: store.directory)
            assert(reopened.configuration(for: id) == config)
            assert(reopened.cube(for: id)?.dimension == dimension)
            print("PASS: \(profile.name) reference grey, gamma/gamut round trip, identity LUT, alpha, configuration persistence")
        }
        for space in ProcessingColorSpace.allCases {
            let ctx = CIContext(options: [.workingColorSpace: space.linear, .workingFormat: CIFormat.RGBAf])
            let input = image(.init(0.2,0.3,0.4,1), space: space.linear)
            func rendered(_ image: CIImage) -> SIMD4<Float> {
                var pixel = SIMD4<Float>(repeating: 0)
                ctx.render(image, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0,y: 0,width: 1,height: 1), format: .RGBAf, colorSpace: space.linear)
                return pixel
            }
            for profile in [LUTProfile.rec709, .sLog3, .vLog, .cLog3, .fLog, .fLog2] {
                let pipeline = LUTPipeline(store: store, configuration: LUTConfiguration(input: profile,output: profile))
                near(rendered(try pipeline.apply(input,id:id)),rendered(input),tolerance:0.0005)
            }
        }
        print("PASS: identity profile conversions in sRGB, Display P3 and Rec.2020 working spaces")
        for (linear, encoded) in [(0.0,0.092864),(0.0005,0.0972318155),(0.18,0.4593184587),(0.9,0.6895033459)] {
            let grey = image(.init(Float(linear),Float(linear),Float(linear),1))
            let result = try transform.encode(grey,profile:.fLog)
            assert(abs(Double(sample(result).x)-encoded)<0.00001)
            near(sample(try transform.decode(result,profile:.fLog)),sample(grey))
        }
        for (linear, encoded) in [(0.0,0.092864),(0.0005,0.0972637305),(0.18,0.3910072419),(0.9,0.5571323640)] {
            let grey = image(.init(Float(linear),Float(linear),Float(linear),1))
            let result = try transform.encode(grey,profile:.fLog2)
            assert(abs(Double(sample(result).x)-encoded)<0.00001)
            near(sample(try transform.decode(result,profile:.fLog2)),sample(grey))
        }
        assert(LUTProfile.fLog2.toXYZ == LUTProfile.fLog.toXYZ)
        let frozen = store.configuration(for: id)
        let pinned = LUTPipeline(store: store, configuration: frozen)
        let pixel = image(.init(0.15,0.3,0.5,1))
        let expected = sample(try pinned.apply(pixel, id: id))
        try store.configure(id, as: LUTConfiguration(input: .sLog3, output: .rec709))
        near(sample(try pinned.apply(pixel, id: id)), expected)
        let changed = sample(try LUTPipeline(store: store).apply(pixel, id: id))
        assert(abs(changed.x - expected.x) > 0.01)
        store.remove(id)
        assert(store.cube(for: id) == nil)
        assert(store.configuration(for: id) == LUTConfiguration())
        print("PASS: different input/output profiles, pinned export configuration, deletion")
    }
}
