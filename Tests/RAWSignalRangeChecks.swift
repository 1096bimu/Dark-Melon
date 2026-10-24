import Foundation
@testable import Dark_Melon

@main struct RAWSignalRangeChecks {
    static func main() {
        var pixels = [Float]()
        for _ in 0..<100_000 { pixels += [0.5,0.3,0.1,1] }
        for i in 0..<9 {
            pixels[i*4] = 100
            pixels[(i+9)*4+2] = -100
        }
        let range = RAWSignalRange.highlight(pixels)!
        assert(range==0.5)
        // A genuine small highlight population survives the tiny tail allowance.
        for i in 20..<40 { pixels[i*4+2] = 0.8 }
        assert(abs(RAWSignalRange.highlight(pixels)!-0.8)<1e-6)
        // Each channel gets its own allowance; alpha and nonfinite data are ignored.
        pixels += [1000,1000,1000,0, .nan,.nan,.nan,1]
        let valid = RAWSignalRange.highlight(pixels)!
        assert(valid.isFinite && abs(valid-0.8)<1e-6)
        assert(RAWSignalRange.highlight([])==nil)
        assert(RAWSignalRange.highlight([1,1,1,0])==nil)
        assert(RAWSignalRange.highlight([.nan,.nan,.nan,1])==nil)
        print("RAW tail trimming rejects isolated extremes, retains populated highlights, and ignores transparent/nonfinite samples.")
    }
}
