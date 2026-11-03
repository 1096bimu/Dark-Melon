import Foundation
@testable import Dark_Melon

@main struct ColorComparisonChecks {
    static func main() {
        var mapping = ToneMapping()
        mapping.vertexWarp[0].chroma = 0.6
        mapping.vertexWarp[1].lightness = 0.12
        mapping.vertexWarp[2].monochromeResponse = 0.3
        mapping.vertexWarp[3].hueOffset = 0.2
        mapping.vertexWarp[4].darkerHue = -0.1
        mapping.vertexWarp[5].lighterHue = 0.15
        mapping.color.monochrome = true
        mapping.color.colorChrome = true
        mapping.color.saturationMid = 0.7
        mapping.color.luminanceSaturationEnd = 1.2
        mapping.whiteBalance.red = 1.3
        mapping.shadowFloor = 0.01
        mapping.clarity = 0.4
        let original = mapping

        var expectedRange = mapping
        expectedRange.vertexWarp = OKLabVertexWarp.defaults
        let range = mapping.comparingColor(chromaRange: true, color: false)
        precondition(range == expectedRange, "Chroma Range compare changed another section")

        var expectedColor = mapping
        expectedColor.color = ColorAdjustments()
        let color = mapping.comparingColor(chromaRange: false, color: true)
        precondition(color == expectedColor, "Color compare changed Chroma Range or another section")
        precondition(mapping.comparingColor(chromaRange: true, color: true)
            == range.comparingColor(chromaRange: false, color: true))
        precondition(mapping.comparingColor(chromaRange: false, color: false) == original)
        precondition(mapping == original, "Compare modified the saved recipe")
        print("PASS: independent Chroma Range and Color comparisons, combined comparison, monochrome node preservation, and unchanged recipe")
    }
}
