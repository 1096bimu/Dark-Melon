import Foundation
@testable import Dark_Melon

@main struct RAWModeRolloffChecks {
    static func main() throws {
        for mode in RAW9Mode.allCases {
            var raw = RAWSettings(); raw.decoderMode = mode
            let loaded = try JSONDecoder().decode(RAWSettings.self, from: JSONEncoder().encode(raw))
            assert(loaded.decoderMode == mode)
            assert(loaded.resolved(using: RAWSettings()).decoderMode == mode)
            let pasted = SettingsPasteSelection(items: [.rawDecoder]).applyingRAW(raw, to: nil)!
            assert(pasted.decoderMode == mode)
            assert(mode.enabled(exporting: false) == (mode == .on))
            assert(mode.enabled(exporting: true) == (mode != .off))
        }
        var legacy = RAWSettings(); legacy.useRAW9 = true
        assert(legacy.decoderMode == .on)
        for tone in [0.0, 0.183, 0.5, 0.99, 1.0] {
            var m = ToneMapping(); m.tonePosition = tone; m.setAutomaticHDRTarget()
            let straight = m.curve(hdr: true)
            for amount in [-1.0, -0.5, 0, 0.5, 1] {
                m.hdrRolloff = amount
                let curve = m.curve(hdr: true)
                assert(abs(curve.value(at: tone) - straight.value(at: tone)) < 0.0001)
                assert(curve.values.allSatisfy { $0.isFinite })
                assert(zip(curve.values, curve.values.dropFirst()).allSatisfy { $0 <= $1 + 1e-9 })
                assert(curve.value(at: 1) <= 2 * straight.value(at: 1) + 1e-9)
                assert(abs(m.hdrMax - max(1, curve.value(at: 1))) < 1e-9)
                if amount < 0 { assert(curve.value(at: 1) >= straight.value(at: 1)) }
            }
        }
        print("PASS: decoder modes persist/paste and distinguish export; signed rolloff preserves join, monotonicity and 2x ceiling")
    }
}
