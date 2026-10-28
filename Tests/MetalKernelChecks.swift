import Foundation
import CoreImage
import Metal
@testable import Dark_Melon

/// Compare the build-time Metal kernels to frozen pre-migration CIKL fixtures.
/// Run from the repository root, linked against the built app.
@main struct MetalKernelChecks {
    struct Fixture: Decodable {
        var name: String
        var color: Bool
        var source: String
        var arguments: [[String]]
    }
    static func main() throws {
        let device = MTLCreateSystemDefaultDevice()!
        let context = CIContext(mtlDevice: device, options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: URL(fileURLWithPath: "Tests/Fixtures/LegacyImageKernels.json")))
        let bounds = CGRect(x: 0, y: 0, width: 32, height: 16)
        func image(_ values: [Float], width: Int, height: Int) -> CIImage {
            values.withUnsafeBytes { bytes in
                CIImage(bitmapData: Data(bytes), bytesPerRow: width * 16,
                    size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: nil)
            }
        }
        var pixels = [Float]()
        for i in 0..<512 {
            let alpha: Float = i % 9 == 0 ? 0 : i % 7 == 0 ? 0.4 : 1
            pixels += [Float(i % 31) / 9 - 0.2, Float(i % 19) / 7, Float(i % 13) / 5, 1].enumerated().map { $0.offset == 3 ? alpha : $0.element * alpha }
        }
        let input = image(pixels, width: 32, height: 16)
        var tableValues = [Float]()
        for i in 0..<512 { let x = Float(i)/511; tableValues += [x*x, x, sqrt(x), 1] }
        let table = image(tableValues, width: 512, height: 1)
        var cubeValues = [Float]()
        for b in 0..<4 { for g in 0..<4 { for r in 0..<4 { cubeValues += [Float(r)/3,Float(g)/3,Float(b)/3,1] } } }
        let cube = image(cubeValues, width: 4, height: 16)
        func vector(_ values: [CGFloat]) -> CIVector { values.withUnsafeBufferPointer { CIVector(values: $0.baseAddress!, count: $0.count) } }
        func argument(_ type: String, _ name: String, variant: Int) -> Any {
            if type == "sampler" || type == "__sample" {
                if name == "table" || name == "tintTable" { return table }
                if name == "cube" { return cube }
                return input
            }
            if type == "float" {
                let values: [String: Double] = ["reference":0.04,"black":0,"span":1,"lastIndex":511,"width":0.1,"position":0.3,"clipping":Double(variant % 2),"amount":variant == 0 ? -0.3 : 0.7,"offset":-0.02,"aspect":2,"exponent":2.3,"profile":Double(variant),"decodeMode":Double(variant % 2),"strength":0.3,"transmission":0.2,"ceiling":4,"monochrome":Double(variant % 2),"dimension":4,"white":0.5,"domain":2,"maximumChroma":0.4,"hasTint":1,"hasWarp":1]
                return values[name] ?? 0.5
            }
            if name == "extent" { return vector([0,0,32,16]) }
            if name == "weights" { return vector([0.2126,0.7152,0.0722]) }
            if name == "slopes" { return vector([0.8,1.1,1.1]) }
            if name == "low" { return vector([0,0,0]) }
            if name == "span" { return vector([1,1,1]) }
            if ["a0","b0","row0","to0","from0"].contains(name) { return vector([1,0,0]) }
            if ["a1","b1","row1","to1","from1"].contains(name) { return vector([0,1,0]) }
            if ["a2","b2","row2","to2","from2"].contains(name) { return vector([0,0,1]) }
            if name.first == "v", let i = Int(name.dropFirst()) { return vector([0.8 + CGFloat(i)*0.03,0.01,0.05,0.3]) }
            if name.first == "h", let i = Int(name.dropFirst()) { return vector([CGFloat(i)*2 * .pi/7,CGFloat(i+1)*2 * .pi/7]) }
            if name.first == "b", Int(name.dropFirst()) != nil { return vector([0.2,0.8,0.03,-0.03]) }
            return vector(type == "vec4" ? [0.8,1.1,0.9,1.2] : type == "vec3" ? [1,0.7,1.3] : [0.8,1.2])
        }
        func render(_ kernel: CIKernel, _ args: [Any]) -> [Float] {
            let result: CIImage?
            if let color = kernel as? CIColorKernel { result = color.apply(extent: bounds, arguments: args) }
            else { result = kernel.apply(extent: bounds, roiCallback: { _, _ in CGRect(x: 0,y: 0,width: 512,height: 16) }, arguments: args) }
            precondition(result != nil)
            var values = [Float](repeating: 0, count: 512*4)
            context.render(result!, toBitmap: &values, rowBytes: 32*16, bounds: bounds, format: .RGBAf, colorSpace: nil)
            return values
        }
        for fixture in fixtures {
            let legacy = CIKernel(source: fixture.source)!
            let modern: CIKernel? = fixture.color ? MetalImageKernels.color(fixture.name) : MetalImageKernels.general(fixture.name)
            precondition(modern != nil, "Missing \(fixture.name)")
            var worst: Float = 0
            for variant in 0..<7 {
                let args = fixture.arguments.map { argument($0[0], $0[1], variant: variant) }
                let a = render(legacy,args), b = render(modern!,args)
                for (x,y) in zip(a,b) {
                    precondition(x.isFinite && y.isFinite, "Nonfinite \(fixture.name)")
                    let error = abs(x-y) / max(1,abs(x))
                    worst = max(worst,error)
                    precondition(error < 0.00002, "\(fixture.name): legacy \(x), Metal \(y)")
                }
            }
            print("\(fixture.name): maximum relative/absolute error \(worst)")
        }
    }
}
