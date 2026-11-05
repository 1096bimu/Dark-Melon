import CoreImage
import Foundation
@testable import Dark_Melon

@main struct PreviewCancellationChecks {
    static func main() async throws {
        let space = ProcessingColorSpace.sRGB
        let context = CIContext(options: [.workingColorSpace: space.linear, .workingFormat: CIFormat.RGBAf])
        let extent = CGRect(x: 0, y: 0, width: 1024, height: 768)
        let input = CIImage(color: CIColor(red: 0.2, green: 0.3, blue: 0.4)).cropped(to: extent)
        let source = context.createCGImage(input, from: extent, format: .RGBAh, colorSpace: space.linear)!
        let worker = RAWDeveloper(colorSpace: space, interactive: true)
        let reference = RAWDeveloper(colorSpace: space)
        var mapping = ToneMapping.fresh(isRAW: false, sourceHeadroom: 2)
        mapping.hdf = 0.05
        _ = try await worker.previews(source, mapping: mapping)
        func sample(_ image: CGImage) -> [Float] {
            var rgba = [Float](repeating: 0, count: 4)
            context.render(CIImage(cgImage: image), toBitmap: &rgba, rowBytes: 16,
                bounds: CGRect(x: 400, y: 300, width: 1, height: 1), format: .RGBAf, colorSpace: space.linear)
            return rgba
        }
        var cancelled = 0
        for iteration in 0..<30 {
            mapping.color.saturationMid = 0.6 + Double(iteration % 6) * 0.1
            let current = mapping
            let render = Task { try await worker.previews(source, mapping: current) }
            try await Task.sleep(for: .nanoseconds([50_000, 150_000, 400_000, 1_000_000, 2_000_000][iteration % 5]))
            render.cancel()
            do { _ = try await render.value }
            catch is CancellationError { cancelled += 1 }
            // Reuse the same context/inputs after interrupted work, as a slider does.
            let actual = try await worker.previews(source, mapping: current)
            let expected = try await reference.previews(source, mapping: current)
            for (a, b) in [(actual.sdr, expected.sdr), (actual.hdr, expected.hdr)] {
                let pixels = sample(a), wanted = sample(b)
                precondition(pixels.prefix(3).contains { $0 > 0.01 }, "Overview went black after cancellation")
                precondition(zip(pixels, wanted).allSatisfy { abs($0 - $1) < 0.012 },
                    "Cancelled batch corrupted a later preview: \(pixels) vs \(wanted)")
            }
        }
        precondition(cancelled > 0, "The stress run did not exercise cancellation")
        print("PASS: \(cancelled) interrupted GPU batches, subsequent SDR/HDR pixels, and retained overview data")
    }
}
