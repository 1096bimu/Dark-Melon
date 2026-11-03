import Foundation

/// Version 1: Crockford Base32, fixed little-endian payload and CRC-16/CCITT.
/// Seed codes: version, kind, seed64, strength16, RGB signed16, checksum16 (32 symbols).
/// Older/manual matrices use an explicit Float32 payload instead of inventing a seed.
nonisolated enum CrossProcessingCode {
    struct Generator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }
    struct Value: Equatable {
        var mixers: DyeMixers
        var rgb: [Double]
    }
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ".utf8)
    private static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 { crc = (crc & 0x8000) != 0 ? (crc &<< 1) ^ 0x1021 : crc &<< 1 }
        }
        return crc
    }
    private static func append(_ value: UInt64, count: Int, to bytes: inout [UInt8]) {
        for i in 0..<count { bytes.append(UInt8(truncatingIfNeeded: value >> (i * 8))) }
    }
    static func encode(mixers: DyeMixers, rgb: [Double]) -> String {
        guard mixers.isValid, rgb.count == 3, rgb.allSatisfy({ $0.isFinite && (-1...1).contains($0) }) else { return "" }
        var generation = mixers.generation
        if generation == nil && mixers.isIdentity { generation = .init(seed: 0, strength: 0) }
        if let g = generation {
            let regenerated = DyeMixers.seeded(g)
            if regenerated?.a != mixers.a || regenerated?.b != mixers.b { generation = nil }
        }
        var bytes: [UInt8] = [1, generation == nil ? 1 : 0]
        if let g = generation {
            append(g.seed, count: 8, to: &bytes)
            append(UInt64(g.strength), count: 2, to: &bytes)
        } else {
            for value in mixers.a + mixers.b { append(UInt64(Float(value).bitPattern), count: 4, to: &bytes) }
        }
        for value in rgb {
            append(UInt64(UInt16(bitPattern: Int16((value * 32767).rounded()))), count: 2, to: &bytes)
        }
        append(UInt64(checksum(bytes)), count: 2, to: &bytes)
        var buffer: UInt32 = 0, bits = 0, result = [UInt8]()
        for byte in bytes {
            buffer = (buffer << 8) | UInt32(byte); bits += 8
            while bits >= 5 { bits -= 5; result.append(alphabet[Int((buffer >> bits) & 31)]) }
            buffer &= (1 << bits) - 1
        }
        if bits > 0 { result.append(alphabet[Int((buffer << (5 - bits)) & 31)]) }
        return String(decoding: result, as: UTF8.self)
    }
    static func decode(_ text: String) -> Value? {
        guard text.utf8.count <= 512 else { return nil }
        var bytes = [UInt8](), buffer: UInt32 = 0, bits = 0, symbols = 0
        for var symbol in text.uppercased().utf8 {
            if symbol == 45 || symbol == 32 || symbol == 10 || symbol == 13 || symbol == 9 { continue }
            if symbol == 79 { symbol = 48 } // O → 0, I/L → 1
            if symbol == 73 || symbol == 76 { symbol = 49 }
            guard let value = alphabet.firstIndex(of: symbol) else { return nil }
            symbols += 1
            buffer = (buffer << 5) | UInt32(value); bits += 5
            if bits >= 8 { bits -= 8; bytes.append(UInt8((buffer >> bits) & 255)) }
            buffer &= (1 << bits) - 1
        }
        guard (symbols == 32 || symbols == 132), buffer == 0, bytes.count == 20 || bytes.count == 82, bytes[0] == 1 else { return nil }
        func read(_ offset: Int, _ count: Int) -> UInt64 {
            (0..<count).reduce(0) { $0 | (UInt64(bytes[offset + $1]) << ($1 * 8)) }
        }
        guard UInt16(read(bytes.count - 2, 2)) == checksum(Array(bytes.dropLast(2))) else { return nil }
        let mixers: DyeMixers
        let rgbOffset: Int
        if bytes[1] == 0 && bytes.count == 20 {
            guard let generated = DyeMixers.seeded(.init(seed: read(2, 8), strength: UInt16(read(10, 2)))) else { return nil }
            mixers = generated; rgbOffset = 12
        } else if bytes[1] == 1 && bytes.count == 82 {
            let numbers = (0..<18).map { Double(Float(bitPattern: UInt32(read(2 + $0 * 4, 4)))) }
            var explicit = DyeMixers()
            explicit.a = Array(numbers.prefix(9)); explicit.b = Array(numbers.suffix(9))
            guard explicit.isValid else { return nil }
            mixers = explicit; rgbOffset = 74
        } else { return nil }
        let rgb = (0..<3).map { Double(Int16(bitPattern: UInt16(read(rgbOffset + $0 * 2, 2)))) / 32767 }
        guard rgb.allSatisfy({ (-1...1).contains($0) }) else { return nil }
        return Value(mixers: mixers, rgb: rgb)
    }
}
