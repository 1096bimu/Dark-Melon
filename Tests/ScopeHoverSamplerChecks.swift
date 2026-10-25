import CoreImage
@testable import Dark_Melon

@main struct ScopeHoverSamplerChecks {
    static func main() async throws {
        let context = CIContext()
        let sampler = ScopeHoverSampler()
        let revision = UUID()
        for space in ProcessingColorSpace.allCases {
            for format in [CIFormat.RGBA8, .RGBAh] {
                let sourceSpace = format == .RGBA8 ? space.encoded : space.linear
                let lower = CIImage(color: CIColor(red: 0.7, green: 0.12, blue: 0.03, alpha: 0.6))
                    .cropped(to: CGRect(x: 0, y: 0, width: 7, height: 3))
                let upper = CIImage(color: CIColor(red: 0.04, green: 0.25, blue: 1.8, alpha: 1))
                    .cropped(to: CGRect(x: 0, y: 3, width: 7, height: 4))
                let image = lower.composited(over: upper)
                let source = context.createCGImage(image, from: CGRect(x: 0, y: 0, width: 7, height: 7),
                    format: format, colorSpace: sourceSpace)!
                for encoded in [false, true] {
                    for position in [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0.5, y: 0.25), CGPoint(x: 0.5, y: 0.75)] {
                        let x = min(6, Int(position.x * 7)), y = min(6, Int(position.y * 7))
                        var pixel = [Float](repeating: 0, count: 4)
                        context.render(CIImage(cgImage: source), toBitmap: &pixel, rowBytes: 16,
                            bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf,
                            colorSpace: encoded ? space.encoded : space.linear)
                        let expected = SIMD3(Double(pixel[0]), Double(pixel[1]), Double(pixel[2])) / Double(pixel[3])
                        for _ in 0..<3 {
                            let actual = try await sampler.sampleRGB(source, revision: revision,
                                position: position, space: space, encoded: encoded)!
                            for c in 0..<3 { assert(abs(actual[c] - expected[c]) < 0.003, "\(space) \(format) \(encoded) \(position): \(actual) vs \(expected)") }
                        }
                    }
                }
            }
        }
        print("PASS: cached samples match Core Image across gamuts, encodings, half/8-bit formats, alpha and row orientation")
    }
}
