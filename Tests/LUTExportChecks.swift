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
        print("LUT export: cube parsing/order, sRGB identity, edited output and spatial exclusion passed.")
    }
}
