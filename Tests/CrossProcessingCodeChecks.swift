import Foundation
@testable import Dark_Melon

@main struct CrossProcessingCodeChecks {
    static func main() throws {
        for seed in UInt64(0)..<100 {
            for strength: UInt16 in [0, 21845, 65535] {
                let mixers = DyeMixers.seeded(.init(seed: seed, strength: strength))!
                let rgb = [-0.2, 0.123456, 1.0]
                let code = CrossProcessingCode.encode(mixers: mixers, rgb: rgb)
                precondition(code.count == 32)
                let restored = CrossProcessingCode.decode(code)!
                precondition(restored.mixers == mixers)
                for i in 0..<3 { precondition(abs(restored.rgb[i] - rgb[i]) <= 0.5 / 32767) }
                precondition(CrossProcessingCode.encode(mixers: restored.mixers, rgb: restored.rgb) == code)
                precondition(CrossProcessingCode.decode(code.lowercased()) == restored)
                precondition(CrossProcessingCode.decode(String(code.dropLast())) == nil)
                precondition(CrossProcessingCode.decode(code + "0") == nil)
                let corrupted = (code.first == "0" ? "1" : "0") + code.dropFirst()
                precondition(CrossProcessingCode.decode(corrupted) == nil)
                let encoded = try JSONEncoder().encode(mixers)
                let decoded = try JSONDecoder().decode(DyeMixers.self, from: encoded)
                precondition(decoded == mixers)
            }
        }
        var manual = DyeMixers.seeded(.init(seed: 42, strength: 21845))!
        manual.a[0] += 0.001
        precondition(manual.generation == nil)
        let code = CrossProcessingCode.encode(mixers: manual, rgb: [0, -1, 1])
        precondition(code.count == 132)
        let restored = CrossProcessingCode.decode(code)!
        for (a,b) in zip(manual.a + manual.b, restored.mixers.a + restored.mixers.b) {
            precondition(abs(a-b) < 1e-6)
        }
        let old = Data("{\"a\":[1,0,0,0,1,0,0,0,1],\"b\":[1,0,0,0,1,0,0,0,1]}".utf8)
        let legacy = try JSONDecoder().decode(DyeMixers.self, from: old)
        precondition(legacy.isIdentity && legacy.generation == nil)
        print("Cross Processing code checks passed")
    }
}
