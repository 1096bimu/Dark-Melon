import Foundation
@testable import Dark_Melon

@main struct ExtendedAdjustmentChecks {
    static func main() throws {
        var mapping = ToneMapping()
        mapping.color.splitTone.nodes = []
        mapping.clarity = 3
        mapping.clarityRadius = 150
        mapping.hdf = 0.5
        mapping.hdfRadius = 400
        mapping.badHDR.strength = -6
        mapping.badHDR.radius = 4
        mapping.halation.radius = 4
        mapping.halation.transmission = 0.8
        mapping.grain.size = 4
        mapping.grain.strength = 7
        mapping.vignette.amount = 6
        mapping.vertexWarp[0].chroma = 3
        mapping.vertexWarp[0].lightness = 0.4
        mapping.color.saturationMid = 3
        mapping.contrastDistribution = [-3, 0, 1, 3]
        mapping.channelContrast = [0.3, -0.3, 0]
        mapping.vertexWarp = OKLabVertexWarp.expanded(mapping.vertexWarp, space: .displayP3)
        let recipe = DevelopmentRecipe(colorSpace: .displayP3, mapping: mapping)
        let restored = try DevelopmentRecipe.decode(recipe.encoded())
        precondition(restored == recipe, "Extended entries must survive saving without clipping")
        let curve = mapping.curve(hdr: false).values
        precondition(curve.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
        for i in 1..<curve.count { precondition(curve[i] >= curve[i-1]) }
        var invalid = recipe
        invalid.mapping.grain.distribution = 1.1
        do { _ = try DevelopmentRecipe.decode(invalid.encoded()); fatalError("Normalized bounds lost") }
        catch RecipeError.invalid { }
        print("PASS: out-of-slider settings round-trip, normalized constraints, finite monotonic tone curves")
    }
}
