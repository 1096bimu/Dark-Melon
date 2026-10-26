import Foundation
import CoreGraphics
@testable import Dark_Melon

@main struct ToneTruncationChecks {
    static func main() {
        for space in ProcessingColorSpace.allCases {
            for white in [ToneMapping.minimumRange, 0.2, 1.0] {
                for contrast in [-0.5, 0, 0.4, 1.0] {
                    var original = ToneMapping()
                    original.white = white
                    original.tonePosition = min(0.04, white)
                    original.concentration = contrast
                    original.contrastDistribution = [-1, 0, 1, 0]
                    let result = ToneTruncation.applying(to: original, space: space)
                    precondition(result.white <= original.white && result.white >= ToneMapping.minimumRange)
                    precondition(abs(result.concentration - contrast * result.white / white) < 1e-12)
                    precondition(result.contrastDistribution == original.contrastDistribution)
                    precondition(result.hdrGain == original.hdrGain && result.hdrRolloff == original.hdrRolloff)
                    precondition(result.tonePosition <= result.white)
                    if result.white > ToneMapping.minimumRange {
                        let output = original.curve(hdr: false).value(at: result.white)
                        let encoded = CGColor(colorSpace: space.linear, components: [output,output,output,1])!
                            .converted(to: space.encoded, intent: .relativeColorimetric, options: nil)!.components![0]
                        precondition(abs(encoded - 254.0 / 255) < 0.00001)
                    }
                }
            }
        }
        print("PASS: SDR threshold, relative contrast scaling, bounds and preservation of other controls")
    }
}
