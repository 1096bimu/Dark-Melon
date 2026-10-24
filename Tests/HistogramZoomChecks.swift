import CoreImage
import Foundation
@testable import Dark_Melon

@main struct HistogramZoomChecks {
    static func main() async throws {
        for white in [ToneMapping.minimumRange, 0.01, 0.1, 0.25, 0.5, 0.75, 1] {
            let maximum = HistogramInputRange.maximum(white: white, hdr: false, encoded: false)
            assert(white / maximum >= 0.5 && white / maximum <= 1)
            assert(HistogramInputRange.maximum(white: white, hdr: true, encoded: false) == 1)
            assert(HistogramInputRange.maximum(white: white, hdr: false, encoded: true) == 1)
            let fraction = white / maximum
            assert(abs(fraction * maximum - white) < 1e-12)
        }
        let samples: [Float] = [0.01, 0.06, 0.15, 0.28, 0.4, 0.49, 0.8, 0.95]
        let values = samples.flatMap { [$0, $0, $0, Float(1)] }
        let data = values.withUnsafeBytes { Data($0) }
        let image = CIImage(bitmapData: data, bytesPerRow: samples.count * 16,
                            size: CGSize(width: samples.count, height: 1), format: .RGBAf,
                            colorSpace: ProcessingColorSpace.sRGB.linear)
        let worker = try GPUHistogram()
        let id = UUID()
        let full = try await worker.calculate(image: image, sourceID: id, bins: 4)
        let zoom = try await worker.calculate(image: image, sourceID: id, bins: 4, upperInput: 0.5)
        for channel in 0..<3 {
            assert(full.histogram[channel] == [3, 3, 0, 2])
            assert(zoom.histogram[channel] == [2, 1, 1, 2])
        }
        assert(zoom.aboveRange == 6 && zoom.belowRange == 0)
        let restored = try await worker.calculate(image: image, sourceID: id, bins: 4)
        assert(restored.histogram == full.histogram)
        print("PASS: half-width SDR range, unchanged HDR/encoded axes, picking coordinates, GPU rebinning and range restoration")
    }
}
