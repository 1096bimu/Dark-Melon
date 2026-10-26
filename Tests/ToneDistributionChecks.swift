import Foundation
import CoreImage
@testable import Dark_Melon

@main struct ToneDistributionChecks {
    @MainActor static func main() async throws {
        // Regression: equally spaced screen handles must share a tangent even
        // when the source intervals are 0–.02–.27–.5, as in the reported corner.
        for peak in [0.0001, 0.08, 0.5, 0.9999] {
            let field = ToneContrastDistribution(peak: peak, weights: [0.25,0.41,1.45,3.03].map { log2($0) })
            let axis = FourPointCubic(positions: field.positions, values: [0,1,2,3])
            for i in 1...2 {
                let xl = axis.bezierControls(segment: i-1), xr = axis.bezierControls(segment: i)
                let yl = field.curve.bezierControls(segment: i-1), yr = field.curve.bezierControls(segment: i)
                let leftSlope = (yl.end-yl.second)/(xl.end-xl.second)
                let rightSlope = (yr.first-yr.start)/(xr.first-xr.start)
                assert(abs(leftSlope-rightSlope) < 1e-8, "Visible corner at handle")
            }
        }
        for white in [ToneMapping.minimumRange, 0.2, 1.0] {
            for mode in [0.0, 0.0001, 0.04, 0.5, 0.9999, 1] {
                for contrast in [-1.0, -0.2, 0, 0.01, 0.4, 1] {
                    var m = ToneMapping()
                    m.white = white; m.tonePosition = mode * white; m.concentration = contrast
                    let base = m.curve(hdr: false).values
                    for common in [-2.0, -0.3, 0, 0.7, 2] {
                        m.contrastDistribution = Array(repeating: common, count: 4)
                        assert(m.curve(hdr: false).values == base, "Equal weights changed the curve")
                    }
                    for weights in [[-2.0,2,-2,2], [2,-2,2,-2], [-1,0,1,0]] {
                        m.contrastDistribution = weights
                        m.setAutomaticHDRTarget()
                        let values = m.curve(hdr: false).values
                        assert(values.first == 0 && abs(values.last! - 1) < 1e-12)
                        assert(values.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1.000000000001 })
                        assert(zip(values,values.dropFirst()).allSatisfy { $0 <= $1 })
                        assert(m.curve(hdr: true).values.allSatisfy(\.isFinite))
                    }
                }
            }
        }
        // Linear log-weights must be reproduced exactly, without flat shoulders.
        for mode in [0.0001, 0.04, 0.5, 0.9999] {
            let knots = [0.0, mode / 2, (mode + 1) / 2, 1.0]
            let field = ToneContrastDistribution(peak: mode, weights: knots.map { 1 - 2 * $0 })
            for i in 0..<3 {
                for j in 0...100 {
                    let t = Double(j) / 100
                    let x = knots[i] + (knots[i+1] - knots[i]) * t
                    assert(abs(field.logWeight(segment: i, fraction: t) - (1 - 2*x)) < 1e-12)
                }
            }
        }
        for mode in [0.0, 0.0001, 0.04, 0.5, 0.9999, 1.0] {
            for logs in [[-2.0,2,-2,2], [2,1,0,-2], [0,0,2,2]] {
                let field = ToneContrastDistribution(peak: mode, weights: logs)
                for i in 0..<3 {
                    for j in 0...100 {
                        let y = field.logWeight(segment: i, fraction: Double(j)/100)
                        assert(y >= min(logs[i],logs[i+1])-1e-12 && y <= max(logs[i],logs[i+1])+1e-12)
                    }
                }
            }
        }
        // Independently integrated exponential weights on a linear base derivative.
        var mapping = ToneMapping()
        mapping.white = 1
        mapping.concentration = 0
        mapping.tonePosition = 0.4
        mapping.contrastDistribution = [1,0.6,-0.4,-1]
        let curve = mapping.curve(hdr: false)
        for x in [0.1,0.3,0.6,0.9] {
            assert(abs(curve.value(at:x) - (1 - pow(2, -2*x)) / 0.75) < 1e-6)
        }
        mapping.concentration = 0.4
        mapping.white = 0.8; mapping.tonePosition = 0.24; mapping.contrastDistribution = [-1, 1, 0, -0.5]
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
        oldMapping.removeValue(forKey: "contrastDistribution"); old["mapping"] = oldMapping
        let legacy = try DevelopmentRecipe.decode(JSONSerialization.data(withJSONObject: old))
        assert(legacy.mapping.contrastDistribution == [0,0,0,0])
        var invalid = recipe; invalid.mapping.contrastDistribution = [0,0,0,2.01]
        do { _ = try DevelopmentRecipe.decode(invalid.encoded()); fatalError("Invalid contrast weights accepted") }
        catch RecipeError.invalid { }
        let selection = SettingsPasteSelection(items: [.contrastDistribution])
        let copied = try CopiedSettings.decode(CopiedSettings.encode(recipe, reference: nil))
        assert(selection.applying(copied.mapping, to: ToneMapping()).contrastDistribution == mapping.contrastDistribution)
        assert(FilmSettings(mapping, selection: selection).applying(to: ToneMapping()).contrastDistribution == mapping.contrastDistribution)
        let defaults = RAWDefaultPreset(recipe: recipe, selection: selection)
        assert(defaults.applying(to: legacy).mapping.contrastDistribution == mapping.contrastDistribution)
        assert(SettingsPasteSelection(tone: true, whiteBalance: false, color: false, effects: false, raw: false).applying(legacy.mapping, to: mapping).contrastDistribution == [0,0,0,0])
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
        var unchanged = mapping; unchanged.contrastDistribution = [0,0,0,0]; unchanged.setAutomaticHDRTarget()
        let before = try await worker.previews(bitmap, mapping: unchanged)
        let after = try await worker.previews(bitmap, mapping: mapping)
        for (a, b) in [(before.sdr, after.sdr), (before.hdr, after.hdr)] {
            assert(zip(pixels(CIImage(cgImage: a)), pixels(CIImage(cgImage: b))).contains { abs($0-$1) > 0.001 })
        }
        var settings = HEIFSettings(); settings.format = .tiff; settings.tiff16Bit = true; settings.tiffHDR = false
        let originalExport = try await worker.exportImage(CIImage(cgImage: bitmap), mapping: unchanged, settings: settings)
        let weightedExport = try await worker.exportImage(CIImage(cgImage: bitmap), mapping: mapping, settings: settings)
        assert(zip(pixels(CIImage(data: originalExport)!), pixels(CIImage(data: weightedExport)!)).contains { abs($0-$1) > 0.001 })
        print("PASS: equal-weight identity, monotonic curves, signed contrast, HDR tangent, ISO, recipes, paste, lock, defaults, reset, undo, preview and export")
    }
}
