import Foundation
import simd

/// Row-major RGB transforms bracketing the film response, before tone mapping.
/// Stored directly, without UI mixer parameters or a baked 3D LUT.
nonisolated struct DyeMixers: Codable, Equatable, Sendable {
    static let identity = [1.0, 0, 0, 0, 1, 0, 0, 0, 1]
    struct Generation: Codable, Equatable, Sendable {
        var seed: UInt64
        var strength: UInt16
    }
    var generation: Generation? = nil
    var a = identity { didSet { generation = nil } }
    var b = identity { didSet { generation = nil } }
    var isIdentity: Bool { a == Self.identity && b == Self.identity }
    var isValid: Bool {
        a.count == 9 && b.count == 9 && (a + b).allSatisfy { $0.isFinite && abs($0) <= 16 }
    }

    // Double's round-trip spelling is locale-independent and loses no precision.
    var text: String { (a + b).map { String($0) }.joined(separator: " ") }
    init() {}
    init?(text: String) {
        let tokens = text.split { $0.isWhitespace || $0 == "," || $0 == ";" }
        guard tokens.count == 18 else { return nil }
        let values = tokens.compactMap { Double($0) }
        guard values.count == 18 else { return nil }
        a = Array(values.prefix(9)); b = Array(values.suffix(9))
        guard isValid else { return nil }
    }

    static func seeded(_ generation: Generation) -> Self? {
        var rng = CrossProcessingCode.Generator(state: generation.seed)
        guard var result = random(strength: 3 * Double(generation.strength) / 65535, using: &rng) else { return nil }
        result.generation = generation
        return result
    }

    /// A preserves neutral exposure. Reject near-singular draws at high strength. B is a
    /// near-inverse with a small neutral-preserving scanner-color perturbation.
    static func random<R: RandomNumberGenerator>(strength: Double = 1, using rng: inout R) -> Self? {
        guard strength.isFinite else { return nil }
        let strength = min(3, max(0, strength))
        guard strength > 0 else { return Self() }
        // Version-1 sampling is explicit rather than Swift's unspecified
        // Double.random implementation, so portable seeds remain reproducible.
        func draw(_ low: Double, _ high: Double) -> Double {
            low + (high - low) * (Double(rng.next() >> 11) / 9007199254740992.0)
        }
        for _ in 0..<64 {
            var result = Self()
            var scanner = Self.identity
            for row in 0..<3 {
                let j = (row + 1) % 3, k = (row + 2) % 3
                let x = draw(0, 0.15 * strength)
                let y = draw(0, 0.15 * strength)
                result.a[row * 3 + j] = x
                result.a[row * 3 + k] = y
                result.a[row * 3 + row] = 1 - x - y
                let u = draw(-0.04 * strength, 0.04 * strength)
                let v = draw(-0.04 * strength, 0.04 * strength)
                scanner[row * 3 + j] = u
                scanner[row * 3 + k] = v
                scanner[row * 3 + row] = 1 - u - v
            }
            func matrix(_ values: [Double]) -> simd_double3x3 {
                simd_double3x3(columns: (SIMD3(values[0], values[3], values[6]),
                                        SIMD3(values[1], values[4], values[7]),
                                        SIMD3(values[2], values[5], values[8])))
            }
            let forward = matrix(result.a)
            guard abs(forward.determinant) >= 0.05 else { continue }
            let back = matrix(scanner) * forward.inverse
            result.b = (0..<9).map { back[$0 % 3][$0 / 3] }
            if result.isValid { return result }
        }
        return nil
    }
}
