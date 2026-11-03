import Foundation

/// Reads source format headers only; never decodes pixels or reads image payloads.
nonisolated enum ImageFileMetadata {
    struct Format: Equatable {
        let bitDepth: Int
        let name: String
    }

    private static func read(_ file: FileHandle, at offset: UInt64, count: Int) -> [UInt8]? {
        guard count >= 0, count <= 4 * 1_048_576 else { return nil }
        do {
            try file.seek(toOffset: offset)
            let data = try file.read(upToCount: count) ?? Data()
            return data.count == count ? Array(data) : nil
        } catch { return nil }
    }

    private static func number(_ bytes: [UInt8], _ offset: Int, _ count: Int, little: Bool = false) -> Int? {
        guard offset >= 0, count > 0, count <= 8, offset <= bytes.count - count else { return nil }
        var value: UInt64 = 0
        for i in 0..<count { value = (value << 8) | UInt64(bytes[offset + (little ? count - 1 - i : i)]) }
        return Int(exactly: value)
    }

    static func jpeg(_ url: URL) -> Format? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard read(file, at: 0, count: 2) == [0xff, 0xd8], let end = try? file.seekToEnd() else { return nil }
        var offset: UInt64 = 2
        var frame: [UInt8]?, adobeTransform: UInt8?
        // Stop at the first scan: gain-map JPEGs can contain another JPEG after the base image.
        for _ in 0..<512 {
            guard offset <= end, end - offset >= 2, let marker = read(file, at: offset, count: 2), marker[0] == 0xff else { return nil }
            let code = marker[1]
            if code == 0xff { offset += 1; continue } // Marker fill bytes.
            if code == 0xda || code == 0xd9 { return frame.flatMap { jpegFrame($0, adobeTransform: adobeTransform) } }
            if code == 1 || (0xd0...0xd7).contains(code) { offset += 2; continue }
            guard let lengthBytes = read(file, at: offset + 2, count: 2), let length = number(lengthBytes, 0, 2),
                  length >= 2, UInt64(length) <= end - offset - 2 else { return nil }
            if code == 0xee, length >= 14, let adobe = read(file, at: offset + 4, count: 12),
               String(decoding: adobe.prefix(5), as: UTF8.self) == "Adobe" { adobeTransform = adobe[11] }
            if (0xc0...0xcf).contains(code), ![0xc4, 0xc8, 0xcc].contains(code) {
                guard frame == nil, length >= 8, let header = read(file, at: offset + 4, count: 6) else { return nil }
                let size = 6 + Int(header[5]) * 3
                guard (1...4).contains(header[5]), size <= length - 2,
                      let data = read(file, at: offset + 4, count: size) else { return nil }
                frame = data
            }
            offset += UInt64(length) + 2
        }
        return nil
    }

    private static func jpegFrame(_ frame: [UInt8], adobeTransform: UInt8?) -> Format? {
        let depth = Int(frame[0]), count = Int(frame[5])
        guard (1...16).contains(depth) else { return nil }
        if count == 1 { return Format(bitDepth: depth, name: String(localized: "Monochrome")) }
        if count == 4 { return Format(bitDepth: depth, name: adobeTransform == 2 ? "YCCK" : "CMYK") }
        guard count == 3 else { return nil }
        let identifiers = (0..<3).map { frame[6 + $0 * 3] }
        if identifiers == Array("RGB".utf8) || adobeTransform == 0 { return Format(bitDepth: depth, name: "RGB") }
        let sampling = (0..<3).map { frame[7 + $0 * 3] }
        let h = sampling.map { Int($0 >> 4) }, v = sampling.map { Int($0 & 15) }
        guard (h + v).allSatisfy({ (1...4).contains($0) }) else { return nil }
        let y = identifiers.firstIndex(of: 1) ?? 0
        let chroma = (0..<3).filter { $0 != y }
        guard h[chroma[0]] == h[chroma[1]], v[chroma[0]] == v[chroma[1]],
              h[y] % h[chroma[0]] == 0, v[y] % v[chroma[0]] == 0 else { return Format(bitDepth: depth, name: "YCbCr") }
        let suffix: String
        switch (h[y] / h[chroma[0]], v[y] / v[chroma[0]]) {
        case (1, 1): suffix = "4:4:4"
        case (2, 1): suffix = "4:2:2"
        case (2, 2): suffix = "4:2:0"
        case (1, 2): suffix = "4:4:0"
        case (4, 1): suffix = "4:1:1"
        case (4, 2): suffix = "4:1:0"
        default: return Format(bitDepth: depth, name: "YCbCr")
        }
        return Format(bitDepth: depth, name: "YCbCr \(suffix)")
    }

    private struct Box {
        let type: String
        let payload: Range<Int>
    }
    private static func boxes(_ bytes: [UInt8], in range: Range<Int>) -> [Box] {
        var result: [Box] = [], offset = range.lowerBound
        while offset <= range.upperBound - 8, result.count < 4096 {
            guard var size = number(bytes, offset, 4) else { break }
            var header = 8
            if size == 1 {
                guard let extended = number(bytes, offset + 8, 8) else { break }
                size = extended; header = 16
            } else if size == 0 { size = range.upperBound - offset }
            guard size >= header, size <= range.upperBound - offset else { break }
            result.append(Box(type: String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self),
                              payload: (offset + header)..<(offset + size)))
            offset += size
        }
        return result
    }

    static func heif(_ url: URL) -> Format? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let end = try? file.seekToEnd() else { return nil }
        var offset: UInt64 = 0
        // Skip mdat rather than reading it; meta can occur before or after the pixels.
        for _ in 0..<256 {
            guard offset <= end, end - offset >= 8, let header = read(file, at: offset, count: 8),
                  let shortSize = number(header, 0, 4) else { return nil }
            var size = UInt64(shortSize), headerSize: UInt64 = 8
            if size == 1 {
                guard let extra = read(file, at: offset + 8, count: 8), let large = number(extra, 0, 8) else { return nil }
                size = UInt64(large); headerSize = 16
            } else if size == 0 { size = end - offset }
            guard size >= headerSize, size <= end - offset else { return nil }
            if String(decoding: header[4..<8], as: UTF8.self) == "meta" {
                guard size - headerSize <= 4 * 1_048_576,
                      let bytes = read(file, at: offset + headerSize, count: Int(size - headerSize)) else { return nil }
                return heifMetadata(bytes)
            }
            offset += size
        }
        return nil
    }

    /// Follow primary-image associations (including grid tiles), never thumbnail/auxiliary properties.
    static func heifMetadata(_ bytes: [UInt8]) -> Format? {
        guard bytes.count >= 4 else { return nil }
        let children = boxes(bytes, in: 4..<bytes.count)
        guard let primary = children.first(where: { $0.type == "pitm" }), primary.payload.count >= 4,
              primary.payload.count >= (bytes[primary.payload.lowerBound] == 0 ? 6 : 8),
              let primaryID = number(bytes, primary.payload.lowerBound + 4, bytes[primary.payload.lowerBound] == 0 ? 2 : 4),
              let properties = children.first(where: { $0.type == "iprp" }) else { return nil }
        let propertyBoxes = boxes(bytes, in: properties.payload)
        guard let container = propertyBoxes.first(where: { $0.type == "ipco" }) else { return nil }
        let definitions = boxes(bytes, in: container.payload)
        var associations: [Int: [Int]] = [:], references: [Int: [Int]] = [:]
        for table in propertyBoxes where table.type == "ipma" {
            var cursor = table.payload.lowerBound
            func take(_ count: Int) -> Int? {
                guard cursor <= table.payload.upperBound - count, let value = number(bytes, cursor, count) else { return nil }
                cursor += count; return value
            }
            guard let version = take(1), let flags = take(3), let count = take(4), count <= 4096 else { return nil }
            let wide = flags & 1 != 0
            for _ in 0..<count {
                guard let item = take(version == 0 ? 2 : 4), let count = take(1) else { return nil }
                for _ in 0..<count {
                    guard let property = take(wide ? 2 : 1) else { return nil }
                    associations[item, default: []].append(property & (wide ? 0x7fff : 0x7f))
                }
            }
        }
        if let table = children.first(where: { $0.type == "iref" }), table.payload.count >= 4 {
            let width = bytes[table.payload.lowerBound] == 0 ? 2 : 4
            for reference in boxes(bytes, in: (table.payload.lowerBound + 4)..<table.payload.upperBound) where reference.type == "dimg" {
                let start = reference.payload.lowerBound
                guard let from = number(bytes, start, width), let count = number(bytes, start + width, 2),
                      count <= (reference.payload.count - width - 2) / width else { continue }
                for i in 0..<count {
                    if let to = number(bytes, start + width + 2 + i * width, width) { references[from, default: []].append(to) }
                }
            }
        }
        var pending = [primaryID], visited: Set<Int> = []
        while let item = pending.popLast(), visited.count < 256 {
            guard visited.insert(item).inserted else { continue }
            let attached = (associations[item] ?? []).compactMap { $0 > 0 && $0 <= definitions.count ? definitions[$0 - 1] : nil }
            if let codec = attached.first(where: { $0.type == "hvcC" }), codec.payload.count >= 19 {
                // HEVCDecoderConfigurationRecord: chroma_format, bit_depth_luma_minus8.
                let start = codec.payload.lowerBound
                let chroma = Int(bytes[start + 16] & 3), depth = Int(bytes[start + 17] & 7) + 8
                let names = [String(localized: "Monochrome"), "YCbCr 4:2:0", "YCbCr 4:2:2", "YCbCr 4:4:4"]
                return Format(bitDepth: depth, name: names[chroma])
            }
            pending.append(contentsOf: (references[item] ?? []).reversed())
        }
        return nil
    }

    /// CFA/linear-RAW TIFF IFDs carry source depth; ImageIO often reports a 16-bit decode instead.
    static func rawBitDepth(_ url: URL) -> Int? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let header = read(file, at: 0, count: 8),
              Array(header.prefix(2)) == [0x49, 0x49] || Array(header.prefix(2)) == [0x4d, 0x4d] else { return nil }
        let little = header[0] == 0x49
        guard number(header, 2, 2, little: little) == 42,
              let first = number(header, 4, 4, little: little) else { return nil }
        var pending = [first], visited: Set<Int> = []
        while let offset = pending.popLast(), visited.count < 32 {
            guard offset > 0, visited.insert(offset).inserted,
                  let prefix = read(file, at: UInt64(offset), count: 2),
                  let count = number(prefix, 0, 2, little: little), count <= 4096,
                  let directory = read(file, at: UInt64(offset) + 2, count: count * 12 + 4) else { continue }
            var depth: Int?, photometric: Int?
            for index in 0..<count {
                let at = index * 12
                guard let tag = number(directory, at, 2, little: little), let type = number(directory, at + 2, 2, little: little),
                      let count = number(directory, at + 4, 4, little: little), let value = number(directory, at + 8, 4, little: little) else { continue }
                if tag == 258, type == 3, count > 0 {
                    if count <= 2 { depth = number(directory, at + 8, 2, little: little) }
                    else if let bytes = read(file, at: UInt64(value), count: 2) { depth = number(bytes, 0, 2, little: little) }
                } else if tag == 262, type == 3 { photometric = number(directory, at + 8, 2, little: little) }
                else if tag == 330, type == 4, count > 0, count <= 64 {
                    if count == 1 { pending.append(value) }
                    else if let offsets = read(file, at: UInt64(value), count: count * 4) {
                        for i in 0..<count { if let child = number(offsets, i * 4, 4, little: little) { pending.append(child) } }
                    }
                }
            }
            if let depth, (1...32).contains(depth), photometric == 32803 || photometric == 34892 { return depth }
            if let next = number(directory, count * 12, 4, little: little) { pending.append(next) }
        }
        return nil
    }
}
