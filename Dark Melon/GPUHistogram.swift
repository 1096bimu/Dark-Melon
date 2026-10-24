import CoreImage
import Foundation
import Metal

/// Owns one source texture, independently of preview rendering and export.
actor GPUHistogram {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let context: CIContext
    private let colorSpace: ProcessingColorSpace
    private let encoded: Bool
    private let countPipeline: MTLComputePipelineState
    private let reducePipeline: MTLComputePipelineState
    private var cachedID: UUID?
    private var cachedTexture: MTLTexture?
    private let shardCount = 64

    init(colorSpace: ProcessingColorSpace = .sRGB, encoded: Bool = false) throws {
        self.encoded = encoded
        self.colorSpace = colorSpace
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw HistogramError.unavailable
        }
        self.device = device
        self.queue = queue
        context = CIContext(mtlDevice: device, options: [
            .workingColorSpace: colorSpace.linear,
            .workingFormat: CIFormat.RGBAf,
            .cacheIntermediates: false
        ])
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        guard let count = library.makeFunction(name: "countRGB"),
              let reduce = library.makeFunction(name: "reduceCounts") else {
            throw HistogramError.unavailable
        }
        countPipeline = try device.makeComputePipelineState(function: count)
        reducePipeline = try device.makeComputePipelineState(function: reduce)
    }

    func calculate(image: CIImage, sourceID: UUID, bins: Int, upperInput: Double = 1) async throws -> HistogramData {
        try Task.checkCancellation()
        let bins = max(1, bins)
        let slots = bins * 3 + 2 + 256
        let bounds = image.extent.integral
        guard let command = queue.makeCommandBuffer() else { throw HistogramError.allocation }
        let texture: MTLTexture
        let isNewSource = cachedID != sourceID
        if !isNewSource, let cachedTexture {
            texture = cachedTexture
        } else {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba32Float, width: Int(bounds.width), height: Int(bounds.height), mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
            descriptor.storageMode = .private
            guard let created = device.makeTexture(descriptor: descriptor) else { throw HistogramError.allocation }
            texture = created
            let translated = image.transformed(by: CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
            context.render(translated, to: texture, commandBuffer: command,
                           bounds: CGRect(origin: .zero, size: bounds.size),
                           colorSpace: encoded ? colorSpace.encoded : colorSpace.linear)
        }
        guard let partial = device.makeBuffer(length: slots * shardCount * MemoryLayout<UInt32>.stride,
                                              options: .storageModePrivate),
              let output = device.makeBuffer(length: slots * MemoryLayout<UInt32>.stride,
                                             options: .storageModeShared),
              let clear = command.makeBlitCommandEncoder() else { throw HistogramError.allocation }
        clear.fill(buffer: partial, range: 0..<partial.length, value: 0)
        clear.endEncoding()
        guard let count = command.makeComputeCommandEncoder() else { throw HistogramError.allocation }
        var binCount = UInt32(bins)
        var shards = UInt32(shardCount)
        count.setComputePipelineState(countPipeline)
        count.setTexture(texture, index: 0)
        count.setBuffer(partial, offset: 0, index: 0)
        count.setBytes(&binCount, length: 4, index: 1)
        count.setBytes(&shards, length: 4, index: 2)
        let weights = colorSpace.luminance
        var statistics = SIMD4<Float>(Float(weights.x), Float(weights.y), Float(weights.z), encoded ? 1 : 0)
        count.setBytes(&statistics, length: 16, index: 3)
        var upper = Float(max(Double.leastNormalMagnitude, upperInput))
        count.setBytes(&upper, length: 4, index: 4)
        let groupWidth = countPipeline.threadExecutionWidth
        let groupHeight = max(1, min(8, countPipeline.maxTotalThreadsPerThreadgroup / groupWidth))
        count.dispatchThreads(MTLSize(width: texture.width, height: texture.height, depth: 1),
                              threadsPerThreadgroup: MTLSize(width: groupWidth, height: groupHeight, depth: 1))
        count.endEncoding()
        guard let reduce = command.makeComputeCommandEncoder() else { throw HistogramError.allocation }
        reduce.setComputePipelineState(reducePipeline)
        reduce.setBuffer(partial, offset: 0, index: 0)
        reduce.setBuffer(output, offset: 0, index: 1)
        reduce.setBytes(&binCount, length: 4, index: 2)
        reduce.setBytes(&shards, length: 4, index: 3)
        reduce.dispatchThreads(MTLSize(width: slots, height: 1, depth: 1),
                               threadsPerThreadgroup: MTLSize(width: reducePipeline.threadExecutionWidth, height: 1, depth: 1))
        reduce.endEncoding()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            command.addCompletedHandler { finished in
                if let error = finished.error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
            command.commit()
        }
        try Task.checkCancellation()
        if isNewSource {
            cachedID = sourceID
            cachedTexture = texture
        }
        let counts = output.contents().bindMemory(to: UInt32.self, capacity: slots)
        let channels = (0..<3).map { channel in
            (0..<bins).map { Int(counts[channel * bins + $0]) }
        }
        return HistogramData(histogram: channels, belowRange: Int(counts[bins * 3]),
                             aboveRange: Int(counts[bins * 3 + 1]),
                             sdrLuma: encoded ? (0..<256).map { Int(counts[bins * 3 + 2 + $0]) } : nil)
    }

    // Sharding reduces global-atomic contention for images dominated by a few
    // brightness levels. A second GPU pass reduces the shards before readback.
    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void countRGB(texture2d<float, access::read> image [[texture(0)]],
                         device atomic_uint *counts [[buffer(0)]],
                         constant uint &bins [[buffer(1)]], constant uint &shards [[buffer(2)]],
                         constant float4 &statistics [[buffer(3)]],
                         constant float &upper [[buffer(4)]],
                         uint2 p [[thread_position_in_grid]]) {
        if (p.x >= image.get_width() || p.y >= image.get_height()) return;
        uint stride = bins * 3 + 2 + 256;
        uint pixel = p.y * image.get_width() + p.x;
        uint offset = (pixel % shards) * stride;
        float3 rgb = image.read(p).rgb;
        if (statistics.w > 0.0 && all(isfinite(rgb))) {
            uint code = uint(round(clamp(dot(rgb, statistics.xyz), 0.0f, 1.0f) * 255.0f));
            atomic_fetch_add_explicit(counts + offset + bins * 3 + 2 + code, 1u, memory_order_relaxed);
        }
        for (uint c = 0; c < 3; ++c) {
            float value = rgb[c];
            if (!isfinite(value)) continue;
            uint slot;
            if (value < 0.0f) slot = bins * 3;
            else if (value > upper) slot = bins * 3 + 1;
            else slot = c * bins + min(uint(value / upper * float(bins)), bins - 1);
            atomic_fetch_add_explicit(counts + offset + slot, 1u, memory_order_relaxed);
        }
    }
    kernel void reduceCounts(device const uint *partials [[buffer(0)]],
                             device uint *output [[buffer(1)]],
                             constant uint &bins [[buffer(2)]], constant uint &shards [[buffer(3)]],
                             uint slot [[thread_position_in_grid]]) {
        uint stride = bins * 3 + 2 + 256;
        if (slot >= stride) return;
        uint total = 0;
        for (uint shard = 0; shard < shards; ++shard) total += partials[shard * stride + slot];
        output[slot] = total;
    }
    """
}

private enum HistogramError: LocalizedError {
    case unavailable, allocation
    var errorDescription: String? {
        switch self {
        case .unavailable: String(localized: "Metal histogram processing is unavailable on this device.")
        case .allocation: String(localized: "Unable to allocate GPU resources for the histogram.")
        }
    }
}
