import CoreImage
import Foundation

nonisolated struct LUTCube: Sendable {
    let dimension: Int
    let data: Data
    let minimum: SIMD3<Double>
    let maximum: SIMD3<Double>

    init(data: Data) throws {
        guard data.count <= 96 * 1024 * 1024,
              let text = String(data: data, encoding: .utf8) else { throw LUTError.invalid }
        var size: Int?
        var minimum = SIMD3<Double>(repeating: 0), maximum = SIMD3<Double>(repeating: 1)
        var values: [Float] = []
        for line in text.replacingOccurrences(of: "\u{feff}", with: "").split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .split(whereSeparator: \.isWhitespace)
            guard let first = fields.first else { continue }
            switch first.uppercased() {
            case "TITLE": continue
            case "LUT_1D_SIZE": throw LUTError.threeDimensional
            case "LUT_3D_SIZE":
                guard size == nil, values.isEmpty, fields.count == 2,
                      let count = Int(fields[1]), (2...128).contains(count) else { throw LUTError.invalid }
                size = count
                values.reserveCapacity(count * count * count * 4)
            case "DOMAIN_MIN", "DOMAIN_MAX":
                guard fields.count == 4 else { throw LUTError.invalid }
                let numbers = fields.dropFirst().compactMap { Double($0) }
                guard numbers.count == 3, numbers.allSatisfy(\.isFinite) else { throw LUTError.invalid }
                let vector = SIMD3(numbers[0], numbers[1], numbers[2])
                if first.uppercased() == "DOMAIN_MIN" { minimum = vector } else { maximum = vector }
            case "LUT_3D_INPUT_RANGE":
                guard fields.count == 3, let low = Double(fields[1]), let high = Double(fields[2]),
                      low.isFinite, high.isFinite else { throw LUTError.invalid }
                minimum = SIMD3(repeating: low); maximum = SIMD3(repeating: high)
            default:
                guard let size, fields.count == 3, values.count < size * size * size * 4 else { throw LUTError.invalid }
                let rgb = fields.compactMap { Float($0) }
                guard rgb.count == 3, rgb.allSatisfy(\.isFinite) else { throw LUTError.invalid }
                values.append(contentsOf: rgb); values.append(1)
            }
        }
        guard let size, values.count == size * size * size * 4,
              (0..<3).allSatisfy({
                  Float(minimum[$0]).isFinite && Float(maximum[$0]).isFinite
                    && Float(maximum[$0] - minimum[$0]).isFinite && Float(maximum[$0] - minimum[$0]) > 0
              }) else { throw LUTError.invalid }
        dimension = size
        self.data = values.withUnsafeBytes { Data($0) }
        self.minimum = minimum; self.maximum = maximum
    }
}

/// Immutable assets, named by UUID rather than source path. NSCache is thread safe;
/// independent preview/export workers share parsed cubes without sharing filters.
nonisolated final class LUTStore: @unchecked Sendable {
    static let shared = LUTStore()
    let directory: URL
    private final class Box: NSObject {
        let cube: LUTCube
        init(_ cube: LUTCube) { self.cube = cube }
    }
    private let cache = NSCache<NSUUID, Box>()
    private let loadLock = NSLock()
    private let bundledDirectory: URL?
    init(directory: URL? = nil) {
        bundledDirectory = Bundle.main.resourceURL
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dark Melon/LUTs", isDirectory: true)
        cache.totalCostLimit = 64 * 1024 * 1024
    }
    func url(for id: UUID) -> URL { directory.appendingPathComponent(id.uuidString).appendingPathExtension("cube") }
    func importFile(_ source: URL) throws -> UUID {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        guard (try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 96 * 1024 * 1024 else { throw LUTError.invalid }
        let data = try Data(contentsOf: source)
        let cube = try LUTCube(data: data)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID()
        try data.write(to: url(for: id), options: .atomic)
        cache.setObject(Box(cube), forKey: id as NSUUID, cost: cube.data.count)
        return id
    }
    func cube(for id: UUID) -> LUTCube? {
        // Batch workers must not parse the same large file concurrently.
        loadLock.lock()
        defer { loadLock.unlock() }
        let local = url(for: id)
        let bundled = bundledDirectory.map { root in
            let folder = root.appendingPathComponent("BundledLUTs").appendingPathComponent(local.lastPathComponent)
            return FileManager.default.fileExists(atPath: folder.path) ? folder : root.appendingPathComponent(local.lastPathComponent)
        }
        let url = FileManager.default.fileExists(atPath: local.path) ? local : bundled ?? local
        guard FileManager.default.fileExists(atPath: url.path) else {
            cache.removeObject(forKey: id as NSUUID)
            return nil
        }
        if let cached = cache.object(forKey: id as NSUUID) { return cached.cube }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 96 * 1024 * 1024,
              let data = try? Data(contentsOf: url), let cube = try? LUTCube(data: data) else { return nil }
        cache.setObject(Box(cube), forKey: id as NSUUID, cost: cube.data.count)
        return cube
    }
    func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
        cache.removeObject(forKey: id as NSUUID)
    }
}

nonisolated final class LUTPipeline {
    private let store: LUTStore
    init(store: LUTStore = .shared) { self.store = store }
    private let domain = CIColorKernel(source: """
        kernel vec4 lutDomain(__sample source, vec3 low, vec3 span) {
            vec4 p = unpremultiply(source);
            // Clamp HDR to SDR white before applying the LUT's declared domain.
            p.rgb = (clamp(p.rgb, 0.0, 1.0) - low) / span;
            return premultiply(p);
        }
        """)
    func apply(_ image: CIImage, id: UUID?) throws -> CIImage {
        guard let id, let cube = store.cube(for: id) else { return image }
        let span = cube.maximum - cube.minimum
        guard let input = domain?.apply(extent: image.extent, arguments: [
            image, CIVector(x: cube.minimum.x,y: cube.minimum.y,z: cube.minimum.z),
            CIVector(x: span.x,y: span.y,z: span.z)
        ]), let filter = CIFilter(name: "CIColorCubeWithColorSpace", parameters: [
            kCIInputImageKey: input, "inputCubeDimension": cube.dimension,
            // Interpret the cube in encoded sRGB, matching StudioCamera's LUT stage.
            "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB)!,
            "inputCubeData": cube.data, "inputExtrapolate": false
        ]), let output = filter.outputImage else { throw LUTError.invalid }
        return output
    }
}

private enum LUTError: LocalizedError {
    case invalid, threeDimensional
    var errorDescription: String? {
        switch self {
        case .invalid: String(localized: "Invalid or unsupported .cube LUT.")
        case .threeDimensional: String(localized: "Only 3D .cube LUTs are supported.")
        }
    }
}
