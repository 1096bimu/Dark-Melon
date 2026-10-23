import CoreGraphics
import Foundation
@testable import Dark_Melon

@main struct SDRDynamicRangeChecks {
    static func main() {
        for space in ProcessingColorSpace.allCases {
            var mapping = ToneMapping()
            mapping.concentration = 0
            func linear(_ value: Double) -> Double {
                let color = CGColor(colorSpace: space.encoded, components: [value,value,value,1])!
                return Double(color.converted(to: space.linear, intent: .relativeColorimetric, options: nil)!.components![0])
            }
            let expected = log2(linear(250.0/255) / linear(3.0/255))
            let measured = SDRDynamicRange.stops(mapping: mapping, space: space)!
            assert(abs(expected - measured) < 1e-10)
            mapping.white = 0.4
            assert(abs(SDRDynamicRange.stops(mapping: mapping, space: space)! - measured) < 1e-10)
            mapping.channelContrast = [0.2,-0.2,0.1]
            mapping.hdrGain = 5
            assert(abs(SDRDynamicRange.stops(mapping: mapping, space: space)! - measured) < 1e-10)
            mapping.concentration = 0.6
            let changed = SDRDynamicRange.stops(mapping: mapping, space: space)!
            assert(abs(changed - measured) > 0.01)
            for tone in [0.0, 0.183, 0.4] {
                mapping.tonePosition = tone
                for contrast in [-1.0,0,1] {
                    mapping.concentration = contrast
                    let value = SDRDynamicRange.stops(mapping: mapping, space: space)!
                    assert(value.isFinite && value > 0)
                }
            }
        }
        print("Encoded endpoint inversion, all working spaces, white-scale invariance, Dye/HDR independence, and extreme curves passed.")
    }
}
