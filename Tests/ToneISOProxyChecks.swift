import Foundation
@testable import Dark_Melon

@main struct ToneISOProxyChecks {
    static func main() throws {
        for tone in [0.0, 0.183, 0.5, 1.0] {
            for contrast in [-0.5, 0, 0.2, 0.6, 1] {
                var original = ToneMapping()
                original.tonePosition = tone
                original.concentration = contrast
                let curve = original.curve(hdr: false)
                for ev in [0.0, 1, 2, 5] {
                    let updated = ToneISOProxy.applying(exposure: ev, to: original)
                    assert(abs(updated.white - exp2(-ev)) < 1e-12)
                    assert(abs(updated.tonePosition - tone * exp2(-ev)) < 1e-12)
                    assert(updated.concentration == contrast)
                    assert(updated.hdrGain == original.hdrGain && updated.hdrRolloff == original.hdrRolloff)
                    assert(abs(ToneISOProxy.exposure(white: updated.white) - ev) < 1e-12)
                    let scaled = updated.curve(hdr: false)
                    assert(zip(curve.values, scaled.values).allSatisfy { abs($0 - $1) < 1e-12 })
                    let restored = ToneISOProxy.applying(exposure: 0, to: updated)
                    assert(abs(restored.tonePosition - tone) < 1e-12 && restored.white == 1)
                    // Same shape, evaluated at the multiplied source signal.
                    for x in [0.0, 0.01, 0.1, 0.3] {
                        assert(abs(scaled.value(at: x) - curve.value(at: x * exp2(ev))) < 1e-12)
                    }
                }
            }
        }
        for raw in [-2.5, -1, 0, 1, 2.5] {
            for iso: Double? in [nil, 100, 800] {
                let range = ToneISOProxy.displayRange(sourceISO: iso, rawExposure: raw)
                for ev in [0.0, 1, 5] {
                    let displayed = ToneISOProxy.displayValue(white: exp2(-ev), sourceISO: iso, rawExposure: raw)
                    let expected = iso.map { $0 * exp2(raw + ev) } ?? (raw + ev)
                    assert(abs(displayed - expected) < 1e-9)
                    assert(range.contains(displayed))
                    let parsed = ToneISOProxy.adjustment(displayValue: displayed, sourceISO: iso, rawExposure: raw)
                    assert(abs(parsed - ev) < 1e-12)
                }
            }
        }
        assert(ToneISOProxy.exposure(white: 1) == 0)
        assert(ToneISOProxy.displayValue(white: 1, sourceISO: nil, rawExposure: -2.5) == -2.5)
        assert(ToneISOProxy.displayValue(white: 0.5, sourceISO: 100, rawExposure: -1) == 100)
        assert(ToneISOProxy.displayValue(white: 1, sourceISO: 100, rawExposure: 1) == 200)
        assert(ToneISOProxy.displayValue(white: 0.5, sourceISO: 100, rawExposure: 1) == 400)
        var mapping = ToneMapping()
        mapping.white = 0.5; mapping.tonePosition = 0.1
        let result = ToneISOProxy.applying(exposure: 2, to: mapping)
        assert(result.white == 0.25 && result.tonePosition == 0.05)
        assert(100 / result.white == 400)
        assert(ToneISOProxy.applying(exposure: -5, to: mapping).white == 1)
        assert(ToneISOProxy.applying(exposure: 20, to: mapping).white == exp2(-5))
        let recipe = DevelopmentRecipe(colorSpace: .sRGB, mapping: result)
        let decoded = try DevelopmentRecipe.decode(recipe.encoded())
        assert(decoded.mapping == result)
        let text = String(decoding: try recipe.encoded(), as: UTF8.self)
        assert(!text.lowercased().contains("iso"))
        print("PASS: coupled ISO scaling, exact SDR shape, display-only RAW EV/ISO offset, zero-based slider, limits, reversibility, existing recipe storage")
    }
}
