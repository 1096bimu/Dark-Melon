import Foundation
import CoreGraphics
@testable import Dark_Melon

@main struct ToneRampChecks {
    static func main() async throws {
        // Normalized white point and encoded axes keep a linear tone diagonal.
        for white in [ToneMapping.minimumRange, 0.001, 0.18, 0.5, 1, 2] {
            var mapping = ToneMapping.fresh(isRAW: false, sourceHeadroom: 1)
            mapping.grain.output = .additive
            mapping.white = white
            let ramp = mapping.neutralSDRRamp()
            precondition(ramp.count == 257)
            for (index, value) in ramp.enumerated() {
                precondition(abs(value - Double(index)/256) < 1e-12)
            }
        }
        let worker = RAWDeveloper(colorSpace: .sRGB)
        for white in [0.18, 0.5, 1] {
            var mapping = ToneMapping.fresh(isRAW: false, sourceHeadroom: 1)
            mapping.grain.output = .additive
            mapping.white = white; mapping.tonePosition = 0.08 * white; mapping.concentration = 0.4
            mapping.contrastDistribution = ToneContrastDistribution(black: 0.2, shadowWidth: 0.1, highlightWidth: 0.8, white: 0.4)
            let ramp = mapping.neutralSDRRamp()
            // Independent color-profile transfer verifies the axes, rather than
            // copying the preview's transfer-function equations into the test.
            let curve = mapping.curve(hdr: false)
            let space = ProcessingColorSpace.sRGB
            for i in stride(from: 0, through: 256, by: 16) {
                let input = space.linearSDRValue(forCode: Double(i)/256*255) * white
                let expected = space.sdrCode(forLinear: curve.value(at: input)) / 255
                precondition(abs(ramp[i] - expected) < 0.00005)
            }
            // Compare only neutral, tone-only LUT samples. The view itself uses
            // the scalar tone curve and never requests or samples this LUT.
            let lut = try await worker.sampleSDRLUT(mapping: mapping, dimension: 17)
            for i in 0...16 {
                let rgb = lut.sample(SIMD3<Float>(repeating: Float(i)/16))
                for channel in 0..<3 {
                    precondition(abs(Double(rgb[channel]) - ramp[i*16]) < 0.001)
                }
            }
            var unrelated = mapping
            unrelated.hdrGain = 5; unrelated.hdrRolloff = 0.8
            unrelated.channelContrast = [0.2, -0.2, 0]
            unrelated.grain.strength = 2; unrelated.lutID = UUID()
            precondition(unrelated.neutralSDRRamp() == ramp)
        }
        print("PASS: neutral SDR ramp, normalized white, sRGB axes, tone-only LUT parity, no HDR/color/spatial dependence")
    }
}
