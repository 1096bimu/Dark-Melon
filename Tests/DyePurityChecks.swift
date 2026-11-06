import Foundation
import CoreImage
@testable import Dark_Melon

@main struct DyePurityChecks {
    static func main() throws {
        let space = ProcessingColorSpace.sRGB
        let context = CIContext(options: [.workingColorSpace: space.linear, .workingFormat: CIFormat.RGBAf])
        let film = FilmResponse()
        let grain = try FilmGrain()
        let bounds = CGRect(x: 0, y: 0, width: 256, height: 256)
        func source(_ rgb: [Double], alpha: Double = 1) -> CIImage {
            CIImage(color: CIColor(red: rgb[0], green: rgb[1], blue: rgb[2], alpha: alpha, colorSpace: space.linear)!).cropped(to: bounds)
        }
        func pixels(_ image: CIImage) -> [Float] {
            var output = [Float](repeating: 0, count: 256*256*4)
            context.render(image, toBitmap: &output, rowBytes: 256*16, bounds: bounds, format: .RGBAf, colorSpace: space.linear)
            return output
        }
        func matrix(_ m: [Double], _ rgb: [Double]) -> [Double] {
            (0..<3).map { i in max(0, (0..<3).reduce(0) { $0 + m[i*3+$1]*rgb[$1] }) }
        }
        let weights = [[0.0,0.08,0.03], [0.16,0,0.10], [0.06,0.20,0]]
        var mapping = ToneMapping(); mapping.grain.output = .filmDensity
        // Neutral settings reproduce the previously independent Analogue grain.
        for strength in [0.0, 1, 2.5] {
            mapping.grain.strength = strength
            let image = source([0.04,0.3,0.7])
            let a = pixels(try film.apply(to: image, mapping: mapping))
            let b = pixels(try grain.apply(to: image, settings: mapping.grain))
            precondition(a == b)
        }
        mapping.grain.strength = 0
        mapping.channelContrast = [0.2,-0.1,0.1]
        mapping.dyePurity = [0,0.3,0.6]
        mapping.dyeMixers.a = [0.9,0.1,0, 0,0.9,0.1, 0.1,0,0.9]
        mapping.dyeMixers.b = [1,0.05,-0.05, -0.05,1,0.05, 0.05,-0.05,1]
        for rgb in [[0.0,0,0], [0.04,0.3,0.7], [4.0,4,4], [10000.0,10000,10000]] {
            let exposed = matrix(mapping.dyeMixers.a, rgb)
            let slopes = mapping.dyeContrastOffsets.map { 1+$0 }
            let densities = (0..<3).map { i -> Double in
                let h = log(max(exposed[i],1e-30)/4)
                return 0.0025+4/(1+exp(-h*slopes[i]))
            }
            let developed = (0..<3).map { i -> Double in
                var d = densities[i]
                for j in 0..<3 { d += 3*weights[i][j]*(1-mapping.dyePurity[j])*(densities[j]-densities[i]) }
                return 1-exp(-max(0,d))
            }
            let expected = matrix(mapping.dyeMixers.b, developed)
            let actual = pixels(try film.apply(to: source(rgb, alpha: 0.7), mapping: mapping))
            for c in 0..<3 { precondition(abs(Double(actual[c])-expected[c]*0.7) < 3e-6) }
            precondition(abs(actual[3]-0.7) < 1e-6)
        }
        // Purity acts on the noise, not only the clean image. Recover densities
        // from pure output and verify the cross-absorption at every pixel.
        mapping.dyeMixers = DyeMixers(); mapping.grain.strength = 2
        mapping.grain.colorScale = 1
        var pure = mapping; pure.dyePurity = [1,1,1]
        let image = source([0.04,0.3,0.7])
        let a = pixels(try film.apply(to: image, mapping: pure))
        let b = pixels(try film.apply(to: image, mapping: mapping))
        for index in stride(from: 0, to: a.count, by: 4) {
            let d = (0..<3).map { -log(1-Double(a[index+$0])) }
            for i in 0..<3 {
                var mixed = d[i]
                for j in 0..<3 { mixed += 3*weights[i][j]*(1-mapping.dyePurity[j])*(d[j]-d[i]) }
                precondition(abs(Double(b[index+i])-(1-exp(-mixed))) < 3e-6)
            }
        }
        // Digital ignores the dormant dye controls and keeps both matrices.
        mapping.grain.output = .additive
        var neutral = mapping; neutral.channelContrast = [0,0,0]; neutral.dyePurity = [1,1,1]
        let digital = pixels(try film.apply(to: image, mapping: mapping))
        let digitalNeutral = pixels(try film.apply(to: image, mapping: neutral))
        precondition(digital == digitalNeutral)
        for mode in [FilmGrainSettings.Output.additive, .filmDensity] {
            mapping.grain.output = mode
            let transparent = pixels(try film.apply(to: source([0,0,0], alpha: 0), mapping: mapping))
            precondition(transparent.allSatisfy { $0 == 0 })
            let pasted = SettingsPasteSelection(items: [.dyeResponse]).applying(mapping, to: ToneMapping())
            precondition(pasted.grain.output == mode && pasted.dyePurity == mapping.dyePurity)
            let recipe = DevelopmentRecipe(colorSpace: space, mapping: mapping)
            let restored = try DevelopmentRecipe.decode(recipe.encoded())
            precondition(restored == recipe)
            let effectCompare = mapping.comparingEffects(crossProcessing: false, effects: true)
            precondition(effectCompare.grain == mapping.grain)
            precondition(effectCompare.dyePurity == mapping.dyePurity)
            let crossCompare = mapping.comparingEffects(crossProcessing: true, effects: false)
            precondition(crossCompare.grain.strength == 0 && crossCompare.grain.output == .additive && crossCompare.dyePurity == [1,1,1])
        }
        print("PASS: neutral Analogue parity, unified layer-density formula, noisy cross-absorption, matrices, Digital isolation, alpha, persistence and section comparisons")
    }
}
