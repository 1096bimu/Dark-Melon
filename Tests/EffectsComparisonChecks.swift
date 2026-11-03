import Foundation
@testable import Dark_Melon

@main struct EffectsComparisonChecks {
    static func main() {
        var mapping = ToneMapping()
        mapping.channelContrast = [0.1, -0.15, 0.2]
        mapping.dyePurity = [0.4, 0.5, 0.6]
        mapping.dyeMixers.a[1] = 0.2
        mapping.clarity = 0.6
        mapping.hdf = 0.1
        mapping.grain.strength = 0.5
        mapping.halation.inputCurve = 0.8
        mapping.vignette.amount = 2
        mapping.badHDR.strength = 0.4
        let original = mapping
        let cross = mapping.comparingEffects(crossProcessing: true, effects: false)
        var expectedCross = mapping
        expectedCross.channelContrast = [0, 0, 0]
        expectedCross.dyeMixers = DyeMixers()
        expectedCross.dyePurity = [1, 1, 1]
        precondition(cross == expectedCross, "Cross compare must only bypass film response")
        let effects = mapping.comparingEffects(crossProcessing: false, effects: true)
        var expectedEffects = mapping
        expectedEffects.clarity = 0
        expectedEffects.hdf = 0
        expectedEffects.grain.strength = 0
        expectedEffects.halation.inputCurve = 0
        expectedEffects.vignette.amount = 0
        expectedEffects.badHDR = BadHDRSettings()
        precondition(effects == expectedEffects, "Effects compare must preserve cross processing")
        precondition(mapping == original)
        precondition(mapping.comparingEffects(crossProcessing: false, effects: false) == original)
        precondition(cross.comparingEffects(crossProcessing: false, effects: true)
            == mapping.comparingEffects(crossProcessing: true, effects: true))
        print("PASS: isolated section bypasses, combined bypass, release and unchanged recipe")
    }
}
