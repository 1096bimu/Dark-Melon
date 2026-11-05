import Foundation
import CoreImage
@testable import Dark_Melon

@main struct ToneDistributionChecks {
    @MainActor static func main() async throws {
        let neutral = ToneContrastDistribution()
        assert(neutral.black == 0 && neutral.shadowWidth == 0.5 && neutral.highlightWidth == 0.5 && neutral.white == 0)
        // Independent copy of the original beta transfer, before distribution.
        func original(_ peak: Double, _ contrast: Double) -> [Double] {
            if contrast == 0 { return (0...2000).map { Double($0) / 2000 } }
            let k = contrast < 0 ? 2.0 : expm1(log(257) * contrast)
            let a = k * peak, b = k * (1 - peak)
            let peakLog = (a == 0 ? 0 : a * log(peak)) + (b == 0 ? 0 : b * log1p(-peak))
            func density(_ x: Double) -> Double {
                let profile = exp(a * log(x) + b * log1p(-x) - peakLog)
                return contrast < 0 ? max(0, 1 - min(1, -contrast) * profile) : profile
            }
            var result = [Double](repeating: 0, count: 2001)
            for i in 0..<2000 {
                result[i+1] = result[i] + (density((Double(i)+0.25)/2000) + density((Double(i)+0.75)/2000))/4000
            }
            let scale = 1 / result[2000]
            return result.map { $0 * scale }
        }
        for white in [ToneMapping.minimumRange, 0.2, 1.0, 2.0] {
            for mode in [0.0, 0.0001, 0.001, 0.08, 0.5, 0.9999, 1] {
                for contrast in [-1.0, -0.2, 0, 0.01, 0.4, 1] {
                    var m = ToneMapping()
                    m.white = white; m.tonePosition = mode * white; m.concentration = contrast
                    let baseline = original(mode, contrast)
                    assert(zip(m.curve(hdr: false).values, baseline).allSatisfy { abs($0-$1) < 1e-14 }, "Default distribution changed the original curve")
                    for width in [0.0, 0.25, 0.5, 1] {
                        for ends in [(0.0, 0.0), (1.0, 1.0), (1.0, 0.25)] {
                            m.contrastDistribution = ToneContrastDistribution(black: ends.0, shadowWidth: width, highlightWidth: width, white: ends.1)
                            let values = m.curve(hdr: false).values
                            assert(values.first == 0 && values.last == 1)
                            assert(values.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
                            assert(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
                            if contrast == 0 && ends.0 == 0 && ends.1 == 0 {
                                assert(values == (0...2000).map { Double($0) / 2000 }, "Width changed identity")
                            }
                        }
                    }
                }
            }
        }
        // Endpoint lifts are direct derivatives, not renormalized weights.
        let black = ToneContrastDistribution(black: 1, shadowWidth: 0.5, highlightWidth: 0.5, white: 0).values(peak: 0.5, contrast: 0.4, count: 20000)
        let white = ToneContrastDistribution(black: 0, shadowWidth: 0.5, highlightWidth: 0.5, white: 1).values(peak: 0.5, contrast: 0.4, count: 20000)
        assert(abs(black[1] * 20000 - 1) < 0.001)
        assert(abs((1 - white[19999]) * 20000 - 1) < 0.001)
        assert(black[19999] > 1-1e-10 && white[1] < 1e-10)
        let shadowLow = ToneContrastDistribution(shadowWidth: 0).values(peak: 0.5, contrast: 0.5)
        let shadowHigh = ToneContrastDistribution(shadowWidth: 1).values(peak: 0.5, contrast: 0.5)
        assert(shadowHigh[500] > shadowLow[500] + 0.01, "Shadows must reverse its effect without reversing its value")
        let highlightLow = ToneContrastDistribution(highlightWidth: 0).values(peak: 0.5, contrast: 0.5)
        let highlightHigh = ToneContrastDistribution(highlightWidth: 1).values(peak: 0.5, contrast: 0.5)
        assert(highlightHigh[1500] > highlightLow[1500] + 0.01)
        for peak in [0.0, 0.0001, 0.001, 0.08, 0.5, 0.9999, 1] {
            for contrast in [-1.0, -0.2, 0, 0.1, 0.5, 1] {
                let baseline = ToneBetaProfile(peak: peak, contrast: contrast, shadowWidth: 0.5, highlightWidth: 0.5, count: 2000)
                for width in [0.0, 0.25, 0.75, 1] {
                    let shaped = ToneBetaProfile(peak: peak, contrast: contrast, shadowWidth: width, highlightWidth: width, count: 2000)
                    assert(abs(shaped.centerSlope - baseline.centerSlope) < 1e-9 * max(1, baseline.centerSlope), "Width changed the slope at Tone")
                    assert(abs(shaped.blackSlope - baseline.blackSlope) < 1e-9 * max(1, baseline.blackSlope))
                    assert(abs(shaped.whiteSlope - baseline.whiteSlope) < 1e-9 * max(1, baseline.whiteSlope))
                }
            }
        }
        // The two settings that used to produce the same concentration must
        // now make different curves rather than acting as duplicate controls.
        let first = ToneContrastDistribution(shadowWidth: 0, highlightWidth: 0).values(peak: 0.5, contrast: 0.1)
        let second = ToneContrastDistribution(shadowWidth: 1, highlightWidth: 1).values(peak: 0.5, contrast: 0.46039753927)
        assert(zip(first, second).map { abs($0-$1) }.max()! > 0.1)
        // Check derivatives of the integrated output, including endpoint edits,
        // independently of the profile's reported central derivative.
        for endpoints in [0.0, 1] {
            var slopes = [Double]()
            for width in [0.0, 0.5, 1] {
                let samples = ToneContrastDistribution(black: endpoints, shadowWidth: width, highlightWidth: width, white: endpoints)
                    .values(peak: 0.5, contrast: 0.5, count: 100000)
                slopes.append((samples[50001] - samples[49999]) * 50000)
            }
            assert(slopes.max()! - slopes.min()! < 0.001, "Rendered central slopes changed with Width")
        }
        // Each side preserves its original mass. Changing one width cannot
        // move the other half, the center brightness, or its tangent.
        for peak in [0.001, 0.08, 0.08317, 0.5, 0.999] {
            for contrast in [-0.5, 0.1, 0.5, 1] {
                for endpoints in [0.0, 1] {
                    let baseline = ToneContrastDistribution(black: endpoints, white: endpoints)
                        .values(peak: peak, contrast: contrast)
                    let baselineCurve = ToneCurve(values: baseline, black: 0, white: 1)
                    for width in [0.0, 1] {
                        let shadows = ToneContrastDistribution(black: endpoints, shadowWidth: width, white: endpoints)
                            .values(peak: peak, contrast: contrast)
                        let highlights = ToneContrastDistribution(black: endpoints, highlightWidth: width, white: endpoints)
                            .values(peak: peak, contrast: contrast)
                        for i in Int(ceil(peak * 2000))...2000 {
                            assert(abs(shadows[i] - baseline[i]) < 1e-9, "Shadow Width moved the highlights")
                        }
                        for i in 0...Int(floor(peak * 2000)) {
                            assert(abs(highlights[i] - baseline[i]) < 1e-9, "Highlight Width moved the shadows")
                        }
                        for values in [shadows, highlights] {
                            assert(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
                            let curve = ToneCurve(values: values, black: 0, white: 1)
                            assert(abs(curve.value(at: peak) - baselineCurve.value(at: peak)) < 0.0001)
                        }
                    }
                }
            }
        }
        var lowTone = ToneMapping(); lowTone.white = 1; lowTone.tonePosition = 0.001
        lowTone.concentration = 0.4
        assert(lowTone.curve(hdr: false).value(at: 0.001) < 0.05, "Tone must not be pinned to 50% output")

        var mapping = ToneMapping()
        mapping.concentration = 0.4
        mapping.white = 0.8; mapping.tonePosition = 0.24
        mapping.contrastDistribution = ToneContrastDistribution(black: 0.5, shadowWidth: 0.25, highlightWidth: 0.9, white: 0.75)
        mapping.setAutomaticHDRTarget()
        let sdr = mapping.curve(hdr: false), hdr = mapping.curve(hdr: true)
        let join = mapping.peakPosition, delta = 0.001
        assert(abs(hdr.value(at: join) - sdr.value(at: join)) < 1e-12)
        assert(abs((hdr.value(at: join + delta) - hdr.value(at: join))/delta - mapping.sdrSlope(at: join, curve: sdr)) < 1e-10)
        let iso = ToneISOProxy.applying(exposure: 2, to: mapping)
        assert(iso.contrastDistribution == mapping.contrastDistribution && iso.curve(hdr: false).values == sdr.values)

        let recipe = DevelopmentRecipe(colorSpace: .displayP3, mapping: mapping)
        let roundtrip = try DevelopmentRecipe.decode(recipe.encoded())
        assert(roundtrip == recipe)
        var old = try JSONSerialization.jsonObject(with: recipe.encoded()) as! [String: Any]
        var oldMapping = old["mapping"] as! [String: Any]
        oldMapping.removeValue(forKey: "storedContrastDistribution")
        oldMapping["storedContrastHandles"] = ["black": 1, "width": 0.8, "white": 1]
        oldMapping["storedContrastShape"] = ["black": 16, "width": 0.8, "white": 8]
        oldMapping["contrastDistribution"] = [-8, 8, 3, -4]
        old["mapping"] = oldMapping
        let legacy = try DevelopmentRecipe.decode(JSONSerialization.data(withJSONObject: old))
        assert(legacy.mapping.contrastDistribution == ToneContrastDistribution())
        let resaved = try JSONSerialization.jsonObject(with: legacy.encoded()) as! [String: Any]
        assert((resaved["mapping"] as! [String: Any])["contrastDistribution"] == nil)
        assert((resaved["mapping"] as! [String: Any])["storedContrastShape"] == nil)
        assert((resaved["mapping"] as! [String: Any])["storedContrastHandles"] == nil)
        assert(legacy.mapping.concentration == mapping.concentration)
        // Even malformed obsolete settings are ignored rather than migrated.
        oldMapping["contrastDistribution"] = "discard me"
        old["mapping"] = oldMapping
        let discarded = try DevelopmentRecipe.decode(JSONSerialization.data(withJSONObject: old))
        assert(discarded == legacy)
        var sharedWidth = old
        var sharedMapping = oldMapping
        sharedMapping["storedContrastDistribution"] = ["black": 0.2, "width": 0.1, "white": 0.8]
        sharedWidth["mapping"] = sharedMapping
        let replaced = try DevelopmentRecipe.decode(JSONSerialization.data(withJSONObject: sharedWidth))
        assert(replaced.mapping.contrastDistribution == ToneContrastDistribution(black: 0.2, white: 0.8))
        let reencoded = try JSONSerialization.jsonObject(with: replaced.encoded()) as! [String: Any]
        let stored = (reencoded["mapping"] as! [String: Any])["storedContrastDistribution"] as! [String: Any]
        assert(stored["width"] == nil && stored["shadowWidth"] as? Double == 0.5 && stored["highlightWidth"] as? Double == 0.5)
        var invalid = recipe; invalid.mapping.contrastDistribution.black = 1.01
        do { _ = try DevelopmentRecipe.decode(invalid.encoded()); fatalError("Invalid endpoint lift accepted") }
        catch RecipeError.invalid { }
        let selection = SettingsPasteSelection(items: [.contrastDistribution])
        let copied = try CopiedSettings.decode(CopiedSettings.encode(recipe, reference: nil))
        assert(selection.applying(copied.mapping, to: ToneMapping()).contrastDistribution == mapping.contrastDistribution)
        assert(FilmSettings(mapping, selection: selection).applying(to: ToneMapping()).contrastDistribution == mapping.contrastDistribution)
        let defaults = RAWDefaultPreset(recipe: recipe, selection: selection)
        assert(defaults.applying(to: legacy).mapping.contrastDistribution == mapping.contrastDistribution)
        assert(SettingsPasteSelection(tone: true, whiteBalance: false, color: false, effects: false, raw: false).applying(legacy.mapping, to: mapping).contrastDistribution == ToneContrastDistribution())
        let history = EditHistory()
        var restored: DevelopmentRecipe?
        history.restore = { restored = $0 }
        history.activate(URL(fileURLWithPath: "/tmp/distribution-test.dng"), recipe: legacy)
        history.observe(recipe); history.flush()
        history.undo(); assert(restored == legacy)
        history.redo(); assert(restored == recipe)
        history.clear()
        let space = ProcessingColorSpace.sRGB
        let context = CIContext(options: [.workingColorSpace: space.linear])
        let image = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 64, y: 32),
            "inputColor0": CIColor(red: 0.01, green: 0.01, blue: 0.01),
            "inputColor1": CIColor(red: 0.8, green: 0.8, blue: 0.8)
        ])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 64, height: 32))
        let bitmap = context.createCGImage(image, from: image.extent, format: .RGBAh, colorSpace: space.linear)!
        func pixels(_ image: CIImage) -> [Float] {
            var values = [Float](repeating: 0, count: 64*32*4)
            context.render(image, toBitmap: &values, rowBytes: 64*16, bounds: image.extent, format: .RGBAf, colorSpace: space.linear)
            return values
        }
        let worker = RAWDeveloper(colorSpace: space)
        var unchanged = mapping; unchanged.contrastDistribution = ToneContrastDistribution(); unchanged.setAutomaticHDRTarget()
        let before = try await worker.previews(bitmap, mapping: unchanged)
        let after = try await worker.previews(bitmap, mapping: mapping)
        for (a, b) in [(before.sdr, after.sdr), (before.hdr, after.hdr)] {
            assert(zip(pixels(CIImage(cgImage: a)), pixels(CIImage(cgImage: b))).contains { abs($0-$1) > 0.001 })
        }
        var settings = HEIFSettings(); settings.format = .tiff; settings.tiff16Bit = true; settings.tiffHDR = false
        let originalExport = try await worker.exportImage(CIImage(cgImage: bitmap), mapping: unchanged, settings: settings)
        let weightedExport = try await worker.exportImage(CIImage(cgImage: bitmap), mapping: mapping, settings: settings)
        assert(zip(pixels(CIImage(data: originalExport)!), pixels(CIImage(data: weightedExport)!)).contains { abs($0-$1) > 0.001 })
        print("PASS: original beta parity, independent shadow/highlight widths, fixed center brightness/slope, endpoint lifts, near-black Tone, identity, monotonic curves, obsolete settings discarded, signed contrast, HDR tangent, ISO, recipes, paste, lock, defaults, reset, undo, preview and export")
    }
}
