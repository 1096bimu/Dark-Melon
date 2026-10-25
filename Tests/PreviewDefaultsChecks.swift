import Foundation
@testable import Dark_Melon

@main struct PreviewDefaultsChecks {
    @MainActor static func main() {
        let cache = EditorDefaultsCache()
        var raw = RAWSettings()
        func resolve(_ isRAW: Bool = true, _ headroom: Double = 1,
                     _ preset: RAWDefaultPreset? = nil) -> DevelopmentRecipe {
            cache.resolve(space: .displayP3, isRAW: isRAW, headroom: headroom,
                          raw: raw, balance: nil, preset: preset)
        }
        let baseline = resolve()
        for _ in 0..<100 { assert(resolve() == baseline) }
        var presetRecipe = baseline
        presetRecipe.mapping.concentration = 0.7
        let preset = RAWDefaultPreset(recipe: presetRecipe,
            selection: SettingsPasteSelection(items: [.contrast]))
        assert(resolve(true, 1, preset).mapping.concentration == 0.7)
        assert(resolve() == baseline)
        assert(resolve(false, 20, preset).mapping.hdrGain == 20)
        assert(resolve(false, 20, preset).mapping.concentration == 0)
        raw.values[.exposure] = -2
        assert(resolve().rawSettings?.values[.exposure] == -2)
        let otherSpace = cache.resolve(space: .sRGB, isRAW: true, headroom: 1,
                                       raw: raw, balance: nil, preset: nil)
        assert(otherSpace.colorSpace == .sRGB)
        print("PASS: defaults cache repeatability and invalidation for preset, source type/headroom, RAW settings, and gamut")
    }
}
