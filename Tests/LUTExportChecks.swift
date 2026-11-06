import Foundation
@testable import Dark_Melon
@main struct LUTExportChecks {
    static func main() async throws {
        let worker = RAWDeveloper(colorSpace: .sRGB)
        let neutral = ToneMapping.fresh(isRAW: false, sourceHeadroom: 1)
        let data = try await worker.exportSDRLUT(mapping: neutral, dimension: 9)
        let cube = try LUTCube(data: data)
        precondition(cube.dimension == 9)
        let values = cube.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        for b in 0..<9 { for g in 0..<9 { for r in 0..<9 {
            let index = ((b * 9 + g) * 9 + r) * 4
            for (channel, expected) in [r,g,b].enumerated() {
                precondition(abs(values[index+channel] - Float(expected)/8) < 0.002, "Identity or cube ordering mismatch")
            }
        } } }
        var edit = neutral
        edit.concentration = 0.3
        edit.dyePurity = [0.2,0.5,0.7]
        let edited = try await worker.exportSDRLUT(mapping: edit, dimension: 9)
        precondition(edited != data)
        edit.grain.strength = 2; edit.hdf = 0.2; edit.clarity = 1
        edit.halation.inputCurve = 1; edit.vignette.amount = 2; edit.badHDR.strength = 1
        let spatial = try await worker.exportSDRLUT(mapping: edit, dimension: 9)
        precondition(spatial == edited, "Spatial effects contaminated the color grid")
        edit.grain.output = .filmDensity
        let analogue = try await worker.exportSDRLUT(mapping: edit, dimension: 9)
        precondition(analogue != edited, "LUT must include the Analogue mean response")
        edit.grain.strength = 0
        let noTexture = try await worker.exportSDRLUT(mapping: edit, dimension: 9)
        precondition(analogue == noTexture, "LUT must exclude noise while retaining the dye response")
        for space in ProcessingColorSpace.allCases {
            let worker = RAWDeveloper(colorSpace: space)
            let identity = try await worker.sampleSDRLUT(mapping: neutral, dimension: 9)
            for white in [ToneMapping.minimumRange, 0.001, 0.18, 0.5, 1, 1.5, 2] {
                var mapping = neutral; mapping.white = white
                let sampled = try await worker.sampleSDRLUT(mapping: mapping, dimension: 9)
                let file = try LUTCube(data: sampled.encoded())
                precondition(file.minimum == .zero && file.maximum == .one, "LUT domain must remain 0–1")
                for b in 0..<9 { for g in 0..<9 { for r in 0..<9 {
                    let index = (b * 9 + g) * 9 + r
                    for (channel, expected) in [r,g,b].enumerated() {
                        precondition(abs(sampled.values[index][channel] - Float(expected) / 8) < 0.002,
                            "Linear curve changed with white: \(space), white \(white), RGB \(r),\(g),\(b), channel \(channel): \(sampled.values[index][channel])")
                        precondition(abs(sampled.values[index][channel] - identity.values[index][channel]) < 0.00002,
                            "White point changed the normalized LUT")
                    }
                } } }
            }
        }
        print("LUT export: cube order, edits/spatial exclusion and full RGB identity across changing white points in three gamuts, with fixed 0–1 domain, passed.")
    }
}
