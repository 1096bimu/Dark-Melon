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
    private var configurations: [UUID: LUTConfiguration] = [:]
    func configuration(for id: UUID) -> LUTConfiguration {
        loadLock.lock(); defer { loadLock.unlock() }
        if let value = configurations[id] { return value }
        let value = (try? Data(contentsOf: configurationURL(id)))
            .flatMap { try? JSONDecoder().decode(LUTConfiguration.self, from: $0) } ?? LUTConfiguration()
        configurations[id] = value
        return value
    }
    private func configurationURL(_ id: UUID) -> URL { url(for: id).deletingPathExtension().appendingPathExtension("json") }
    func configure(_ id: UUID, as configuration: LUTConfiguration) throws {
        try loadLock.withLock {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(configuration).write(to: configurationURL(id), options: .atomic)
            configurations[id] = configuration
        }
        NotificationCenter.default.post(name: .lutConfigurationChanged, object: id)
    }
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
        try? FileManager.default.removeItem(at: configurationURL(id))
        loadLock.lock(); configurations.removeValue(forKey: id); loadLock.unlock()
        cache.removeObject(forKey: id as NSUUID)
    }
}

extension Notification.Name {
    nonisolated static let lutConfigurationChanged = Notification.Name("DarkMelon.lutConfigurationChanged")
}

nonisolated final class LUTPipeline {
    private let store: LUTStore
    var configurationOverride: LUTConfiguration?
    init(store: LUTStore = .shared, configuration: LUTConfiguration? = nil) {
        self.store = store; self.configurationOverride = configuration
    }
    func configuration(for id: UUID?) -> LUTConfiguration? {
        id.map { configurationOverride ?? store.configuration(for: $0) }
    }
    private let profileTransform = LUTProfileTransform()
    // Explicit float sampling avoids the native cube filter's quantization of
    // encoded log values, whose inverse transfer can amplify small LUT errors.
    private let profileCube = MetalImageKernels.general("profileLUT")
    private let domain = MetalImageKernels.color("lutDomain")
    func isAvailable(_ id: UUID?, hdrEnabled: Bool = true) -> Bool {
        guard hdrEnabled || configuration(for: id)?.input.isLog != true else { return false }
        return id.flatMap { store.cube(for: $0) } != nil
    }
    func outputsSDR(_ mapping: ToneMapping) -> Bool {
        mapping.hdrEnabled && configuration(for: mapping.lutID)?.input.isLog == true
            && isAvailable(mapping.lutID)
    }
    func activeID(_ mapping: ToneMapping) -> UUID? {
        isAvailable(mapping.lutID, hdrEnabled: mapping.hdrEnabled) ? mapping.lutID : nil
    }

    private let hdrGain = MetalImageKernels.color("lutHDRGain")

    func applyHDR(_ hdr: CIImage, sdr: CIImage, gradedSDR: CIImage) throws -> CIImage {
        guard let output = hdrGain?.apply(extent: hdr.extent, arguments: [hdr, sdr, gradedSDR]) else {
            throw LUTError.invalid
        }
        return output
    }

    func apply(_ image: CIImage, id: UUID?) throws -> CIImage {
        guard let id, let cube = store.cube(for: id) else { return image }
        let span = cube.maximum - cube.minimum
        let configuration = configuration(for: id) ?? LUTConfiguration()
        if configuration != LUTConfiguration() {
            let encoded = try profileTransform.encode(image, profile: configuration.input)
            let atlas = CIImage(bitmapData: cube.data, bytesPerRow: cube.dimension * 16,
                size: CGSize(width: cube.dimension, height: cube.dimension * cube.dimension), format: .RGBAf, colorSpace: nil)
                .transformed(by: CGAffineTransform(translationX: 0, y: Double(cube.dimension * cube.dimension)).scaledBy(x: 1, y: -1))
            guard let output = profileCube?.apply(extent: image.extent,
                roiCallback: { index, rect in index == 0 ? rect : atlas.extent },
                arguments: [encoded, atlas,
                    CIVector(x: cube.minimum.x, y: cube.minimum.y, z: cube.minimum.z),
                    CIVector(x: span.x, y: span.y, z: span.z), Double(cube.dimension)]) else { throw LUTError.invalid }
            return try profileTransform.decode(output, profile: configuration.output)
        }
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

nonisolated enum LUTError: LocalizedError {
    case invalid, threeDimensional
    var errorDescription: String? {
        switch self {
        case .invalid: String(localized: "Invalid or unsupported .cube LUT.")
        case .threeDimensional: String(localized: "Only 3D .cube LUTs are supported.")
        }
    }
}
