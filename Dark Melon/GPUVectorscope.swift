import CoreImage
import Metal

actor GPUVectorscope {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var context: CIContext
    private let pipeline: MTLComputePipelineState
    private let imagePipeline: MTLComputePipelineState
    private var counts: MTLBuffer?
    private var input: MTLTexture?
    private var developer: RAWDeveloper?
    private var workingSpace: ProcessingColorSpace?
    private let shards = 16
    static let size = 513

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw ScopeError.unavailable
        }
        self.device = device
        self.queue = queue
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        guard let function = library.makeFunction(name: "scopeCount") else { throw ScopeError.unavailable }
        pipeline = try device.makeComputePipelineState(function: function)
        imagePipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "scopeImage")!)
    }

    func render(source: CGImage, mapping: ToneMapping, space: ProcessingColorSpace, zoom: Double) async throws -> ScopeTexture {
        try Task.checkCancellation()
        if workingSpace != space {
            developer = RAWDeveloper(colorSpace: space)
            context = CIContext(mtlDevice: device, options: [.workingColorSpace: space.linear,
                                .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])
            workingSpace = space
        }
        let scale = min(1, 512.0 / Double(max(source.width, source.height)))
        let reduced = CIImage(cgImage: source).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let image = try await developer!.mappedImage(reduced, mapping: mapping, hdr: false)
        try Task.checkCancellation()
        let width = max(1, Int(image.extent.width)), height = max(1, Int(image.extent.height))
        if input?.width != width || input?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                width: width, height: height, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
            descriptor.storageMode = .private
            input = device.makeTexture(descriptor: descriptor)
        }
        let size = Self.size
        if counts == nil { counts = device.makeBuffer(length: size * size * shards * 4, options: .storageModePrivate) }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
            width: size, height: size, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let input, let counts, let output = device.makeTexture(descriptor: descriptor),
              let command = queue.makeCommandBuffer() else { throw ScopeError.unavailable }
        context.render(image, to: input, commandBuffer: command,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: space.encoded)
        guard let clear = command.makeBlitCommandEncoder() else { throw ScopeError.unavailable }
        clear.fill(buffer: counts, range: 0..<counts.length, value: 0)
        clear.endEncoding()
        guard let encoder = command.makeComputeCommandEncoder() else { throw ScopeError.unavailable }
        var magnification = Float(zoom)
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(input, index: 0)
        encoder.setBuffer(counts, offset: 0, index: 0)
        encoder.setBytes(&magnification, length: 4, index: 1)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: pipeline.threadExecutionWidth, height: 4, depth: 1))
        encoder.memoryBarrier(scope: .buffers)
        encoder.setComputePipelineState(imagePipeline)
        encoder.setTexture(output, index: 0)
        var exposure = Float(65536.0 / Double(width * height))
        encoder.setBytes(&exposure, length: 4, index: 1)
        encoder.dispatchThreads(MTLSize(width: size, height: size, depth: 1),
            threadsPerThreadgroup: MTLSize(width: imagePipeline.threadExecutionWidth, height: 4, depth: 1))
        encoder.endEncoding()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            command.addCompletedHandler { buffer in
                if let error = buffer.error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
            command.commit()
        }
        try Task.checkCancellation()
        return ScopeTexture(texture: output, gpuMilliseconds: (command.gpuEndTime - command.gpuStartTime) * 1000)
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void scopeCount(texture2d<float, access::read> source [[texture(0)]],
                           device atomic_uint *counts [[buffer(0)]],
                           constant float &zoom [[buffer(1)]],
                           uint2 p [[thread_position_in_grid]]) {
        if (p.x >= source.get_width() || p.y >= source.get_height()) return;
        float3 rgb = clamp(source.read(p).rgb, 0.0, 1.0);
        // BT.601 Y′UV, matching ScopeProjection. Positive V is upward.
        float luma = dot(rgb, float3(0.299, 0.587, 0.114));
        float2 uv = float2(0.492 * (rgb.b - luma), -0.877 * (rgb.r - luma));
        float2 plotted = uv * (zoom / 0.75);
        if (length(plotted) > 1.000001) return;
        int x = 256 + int(round(plotted.x * 256));
        int y = 256 + int(round(plotted.y * 256));
        uint shard = (p.y * source.get_width() + p.x) % 16;
        atomic_fetch_add_explicit(counts + shard * 513 * 513 + y * 513 + x, 1u, memory_order_relaxed);
    }
    kernel void scopeImage(device const uint *counts [[buffer(0)]],
                           constant float &exposure [[buffer(1)]],
                           texture2d<float, access::write> output [[texture(0)]],
                           uint2 p [[thread_position_in_grid]]) {
        if (p.x >= 513 || p.y >= 513) return;
        uint count = 0;
        for (uint shard = 0; shard < 16; ++shard) count += counts[shard * 513 * 513 + p.y * 513 + p.x];
        float brightness = min(1.0, log(1.0 + float(count) * exposure) / log(4097.0));
        output.write(float4(float3(brightness), 1.0), p);
    }
    """
}

private enum ScopeError: LocalizedError {
    case unavailable
    var errorDescription: String? { "Unable to render the GPU vectorscope." }
}

nonisolated struct ScopeTexture: @unchecked Sendable {
    let texture: MTLTexture
    let gpuMilliseconds: Double
}
