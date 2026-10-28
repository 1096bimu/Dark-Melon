import Foundation
import CoreImage
@testable import Dark_Melon

@main struct DyeMixersChecks {
    struct Generator: RandomNumberGenerator {
        var state: UInt64 = 42
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }
    static func multiply(_ m: [Double], _ rgb: [Double]) -> [Double] {
        (0..<3).map { i in (0..<3).reduce(0.0) { $0 + m[i * 3 + $1] * rgb[$1] } }
    }
    static func response(_ x: Double, reference: Double, offset: Double) -> Double {
        guard x > 0 else { return 0 }
        let h = log2(x / max(1e-6, reference))
        let neutral = 1 / (1 + exp(-h / 2))
        let layer = 1 / (1 + exp(-h * (1 + offset) / 2))
        return x * exp2(8 * (layer - neutral))
    }
    static func main() async throws {
        var mapping = ToneMapping()
        mapping.color.splitTone.nodes = []
        mapping.vertexWarp = OKLabVertexWarp.expanded(mapping.vertexWarp, space: .sRGB)
        var rng = Generator()
        for strength in [0.0, 0.01, 0.1, 0.5, 1, 2, 3] {
            for _ in 0..<100 {
                let pair = DyeMixers.random(strength: strength, using: &rng)!
                precondition(pair.isValid && DyeMixers(text: pair.text) == pair)
                if strength == 0 { precondition(pair.isIdentity) }
                for row in 0..<3 {
                    precondition(pair.a[row * 3 + row] >= 1 - 0.3 * strength)
                    precondition(abs(pair.a[row*3..<row*3+3].reduce(0,+) - 1) < 1e-12)
                    precondition(abs(pair.b[row*3..<row*3+3].reduce(0,+) - 1) < 1e-12)
                }
                mapping.dyeMixers = pair
            }
        }
        precondition(DyeMixers(text: "nan " + mapping.dyeMixers.text) == nil)
        precondition(DyeMixers(text: "1 2 3") == nil)
        let recipe = DevelopmentRecipe(colorSpace: .sRGB, mapping: mapping)
        let decoded = try DevelopmentRecipe.decode(recipe.encoded())
        precondition(decoded.mapping.dyeMixers == mapping.dyeMixers)
        var old = try JSONSerialization.jsonObject(with: recipe.encoded()) as! [String: Any]
        var oldMapping = old["mapping"] as! [String: Any]
        oldMapping.removeValue(forKey: "dyeMixers"); old["mapping"] = oldMapping
        let restored = try DevelopmentRecipe.decode(JSONSerialization.data(withJSONObject: old))
        precondition(restored.mapping.dyeMixers.isIdentity)
        let applied = SettingsPasteSelection(items: [.dyeResponse]).applying(mapping, to: ToneMapping())
        precondition(applied.dyeMixers == mapping.dyeMixers)
        precondition(FilmSettings(mapping).applying(to: ToneMapping()).dyeMixers == mapping.dyeMixers)

        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let context = CIContext(options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAf])
        let film = FilmResponse()
        let developer = RAWDeveloper()
        for tone in [0.0, 0.04, 0.183, 1.0] {
            mapping.tonePosition = tone
            let shades = [0, 1e-6, 0.0001, 0.01, 0.04, 0.183, 0.5, 1, 2, 20, max(tone,1e-6)]
            let colors = shades.map { [$0,$0,$0] } + [[0.09,0.24,0.37], [2,0.2,4]]
            let floats = colors.flatMap { $0.map(Float.init) + [Float(1)] }
            let source = CIImage(bitmapData: floats.withUnsafeBytes { Data($0) }, bytesPerRow: floats.count * 4,
                size: CGSize(width: colors.count,height: 1), format: .RGBAf, colorSpace: space)
            for offsets in [[0.0,0,0],[0.2,-0.2,0.1],[1.0,-1,0]] {
                mapping.channelContrast = offsets
                let image = try film.apply(to: source, mapping: mapping)
                var output = [Float](repeating:0,count:floats.count)
                context.render(image,toBitmap:&output,rowBytes:output.count*4,bounds:source.extent,format:.RGBAf,colorSpace:space)
                for (index, rgb) in colors.enumerated() {
                    let mixed = multiply(mapping.dyeMixers.a,rgb)
                    let curved = mixed.enumerated().map { response(max(0,$0.element),reference:tone,offset:mapping.dyeContrastOffsets[$0.offset]) }
                    let expected = multiply(mapping.dyeMixers.b,curved).map { max(0,$0) }
                    for c in 0..<3 {
                        let value = Double(output[index*4+c])
                        precondition(value.isFinite && abs(value-expected[c]) < 0.0003 * max(1,expected[c]))
                        if offsets == [0,0,0], index < shades.count {
                            precondition(abs(value-rgb[c]) < 0.0003*max(1,rgb[c]), "Neutral axis shifted")
                        }
                    }
                }
                precondition(output[9*4] > 1, "Film stage must preserve HDR headroom")
                // Both display renditions consume the same linear film result.
                for hdr in [false,true] {
                    let curve = mapping.curve(hdr:hdr)
                    let toned = try await developer.applyTone(image,curves:mapping.channelCurves(hdr:hdr))
                    var pixels = output
                    context.render(toned,toBitmap:&pixels,rowBytes:pixels.count*4,bounds:source.extent,format:.RGBAf,colorSpace:space)
                    for i in colors.indices { for c in 0..<3 {
                        precondition(abs(Double(pixels[i*4+c])-curve.value(at:Double(output[i*4+c]))) < 0.004)
                    } }
                }
            }
        }
        mapping.dyeMixers = DyeMixers(); mapping.channelContrast = [0,0,0]
        let unchanged = CIImage(color:.red)
        let bypassed = try film.apply(to:unchanged,mapping:mapping)
        precondition(bypassed === unchanged)
        print("PASS: coordinated random matrices, neutral axis, log-film GPU parity, black/reference/HDR range, identity bypass, shared SDR/HDR input, persistence and lock")
    }
}
