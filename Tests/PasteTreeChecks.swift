import Foundation
@testable import Dark_Melon

@main struct PasteTreeChecks {
    static func main() throws {
        var source = ToneMapping()
        source.concentration = 0.6
        source.hdrGain = 3
        source.whiteBalance.red = 1.3
        source.color.saturationMid = 1.5
        source.color.luminanceSaturationMid = 0.5
        source.vertexWarp[0].chroma = 0.2
        source.vertexWarp[0].darkerHue = 0.4
        source.clarity = 0.8
        source.hdf = 0.1
        source.channelContrast = [0.1,-0.1,0]
        let destination = ToneMapping()
        func selected(_ items: Set<PasteItem>) -> SettingsPasteSelection {
            SettingsPasteSelection(items: items)
        }
        let hdr = selected([.hdrGain]).applying(source,to:destination)
        assert(hdr.hdrGain == 3 && hdr.concentration == destination.concentration && hdr.hdrTarget == destination.hdrTarget)
        let chroma = selected([.chromaCurve]).applying(source,to:destination)
        assert(chroma.color.saturationMid == 1.5 && chroma.color.luminanceSaturationMid == 1)
        let vertices = selected([.vertices]).applying(source,to:destination)
        assert(vertices.vertexWarp[0].chroma == 0.2 && vertices.vertexWarp[0].darkerHue == 0)
        let twist = selected([.hueTwister]).applying(source,to:destination)
        assert(twist.vertexWarp[0].chroma == 1 && twist.vertexWarp[0].darkerHue == 0.4)
        let effect = selected([.clarity]).applying(source,to:destination)
        assert(effect.clarity == 0.8 && effect.hdf == 0 && effect.channelContrast == [0,0,0])
        assert(selected([]).applying(source,to:destination) == destination)
        assert(selected([]).isEmpty)

        var rawSource = RAWSettings()
        rawSource.values = [.exposure: 2, .luminance: 0.7]
        rawSource.lensCorrection = true
        rawSource.highlightRecovery = false
        var rawDestination = RAWSettings()
        rawDestination.values = [.exposure: 0, .luminance: 0.2]
        rawDestination.lensCorrection = true
        let exposure = selected([.exposure]).applyingRAW(rawSource,to:rawDestination)!
        assert(exposure.values[.exposure] == 2 && exposure.values[.luminance] == 0.2 && exposure.lensCorrection)
        let sparse = selected([.exposure]).applyingRAW(rawSource,to:nil)!
        assert(sparse.values == [.exposure:2] && sparse.selectedSwitches == [])
        let resolved = sparse.resolved(using:rawDestination)
        assert(resolved.lensCorrection && resolved.values[.luminance] == 0.2)
        let encodedSparse = try JSONEncoder().encode(sparse)
        let decodedSparse = try JSONDecoder().decode(RAWSettings.self,from:encodedSparse)
        assert(decodedSparse == sparse)
        let switches = selected([.highlightRecovery]).applyingRAW(rawSource,to:nil)!.resolved(using:rawDestination)
        assert(switches.lensCorrection && !switches.highlightRecovery)
        let leaves = selected([.contrast,.vertices,.halation,.exposure])
        let roundtrip = try JSONDecoder().decode(SettingsPasteSelection.self,from:JSONEncoder().encode(leaves))
        assert(roundtrip == leaves)
        let legacy = try JSONDecoder().decode(SettingsPasteSelection.self,from:Data("""
        {"tone":false,"whiteBalance":true,"color":false,"effects":true,"raw":false}
        """.utf8))
        assert(legacy.contains(.rawWhiteBalance) && legacy.contains(.halation) && !legacy.contains(.contrast) && !legacy.contains(.exposure))
        print("Independent tone/color/effect leaves, sparse RAW paste, decoder-default preservation, persistence, and legacy selection migration passed.")
    }
}
