#if DEBUG && os(macOS)
import Foundation
import Metal

/// Generates final SceneKit vertex/color buffers on the GPU, including LUT evaluation.
/// The sampled export grid uploads once per edit; display filters reuse that buffer.
final class LUTPointCloud {
    struct Result {
        let positions: MTLBuffer
        let colors: MTLBuffer
        let vectors: MTLBuffer?
        let sampleCount: Int
        let visibleCount: Int
        let clippedCount: Int
    }

    private struct Uniforms {
        var grid: SIMD4<UInt32>
        var options: SIMD4<UInt32>
        var transform: SIMD4<Float>
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private var table: MTLBuffer?
    private var dimension = 0
    private let dummyBuffer: MTLBuffer

    struct GPUError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let dummy = device.makeBuffer(length: 16, options: .storageModeShared) else {
            throw GPUError(message: "Metal is unavailable on this device.")
        }
        let library = try device.makeLibrary(source: Self.source, options: nil)
        guard let function = library.makeFunction(name: "generateLUTPointCloud") else {
            throw GPUError(message: "The LUT point-cloud shader is unavailable.")
        }
        self.device = device
        self.queue = queue
        self.pipeline = try device.makeComputePipelineState(function: function)
        dummyBuffer = dummy
    }

    func setLUT(_ lut: SDRLUT) throws {
        guard let buffer = lut.values.withUnsafeBytes({ bytes in
            device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
        }) else { throw GPUError(message: "Could not allocate the LUT buffer.") }
        table = buffer
        dimension = lut.dimension
    }

    func generate(_ settings: LUTViewerSettings) throws -> Result {
        guard let table, dimension == Int(settings.density) else {
            throw GPUError(message: "Waiting for the current LUT grid.")
        }
        let n = dimension
        let count = settings.neutrals ? 65 : settings.mode == .cube ? n * n * n : settings.mode == .rays ? 7 * 65 : n * n
        func buffer(_ length: Int) throws -> MTLBuffer {
            guard let result = device.makeBuffer(length: length, options: .storageModeShared) else {
                throw GPUError(message: "Could not allocate point-cloud buffers.")
            }
            return result
        }
        // Each submitted cloud owns its buffers. SceneKit may still be rendering the previous
        // cloud on another command queue, so never overwrite its in-flight resources.
        let positions = try buffer(count * 16)
        let colors = try buffer(count * 16)
        let vectors = settings.vectors ? try buffer(count * 32) : nil
        let counts = try buffer(8)
        counts.contents().initializeMemory(as: UInt32.self, repeating: 0, count: 2)
        let regions = ["All", "R", "G", "B", "C", "M", "Y"]
        var uniforms = Uniforms(
            grid: SIMD4(UInt32(n), settings.mode == .cube ? 0 : settings.mode == .rays ? 1 : 2,
                        UInt32(settings.axis), settings.neutrals ? 1 : 0),
            options: SIMD4(UInt32(regions.firstIndex(of: settings.region) ?? 0),
                           settings.clipping == .off ? 0 : settings.clipping == .highlight ? 1 : 2,
                           settings.vectors ? 1 : 0, UInt32(count)),
            transform: SIMD4(settings.slice, 0, 0, 0))
        guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
            throw GPUError(message: "Could not create the point-cloud compute command.")
        }
        command.label = "Generate and transform LUT points"
        encoder.setComputePipelineState(pipeline)
        encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        for (index, resource) in [table, positions, colors, vectors ?? dummyBuffer, counts].enumerated() {
            encoder.setBuffer(resource, offset: 0, index: index + 1)
        }
        let width = min(256, pipeline.maxTotalThreadsPerThreadgroup)
        encoder.dispatchThreadgroups(MTLSize(width: (count + width - 1) / width, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
        encoder.endEncoding()
        command.commit()
        // Finish before exposing these buffers to SceneKit's separate rendering queue.
        command.waitUntilCompleted()
        if let error = command.error { throw error }
        let stats = counts.contents().assumingMemoryBound(to: UInt32.self)
        return Result(positions: positions, colors: colors, vectors: vectors, sampleCount: count,
                      visibleCount: Int(stats[0]), clippedCount: Int(stats[1]))
    }
    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct CloudUniforms {
        uint4 grid; // density, mode, axis, neutrals
        uint4 options; // region, clipping, vectors, count
        float4 transform; // slice, reserved
    };

    float3 sampleLUT(float3 input, uint n, device const float4 *table) {
        float3 p = clamp(input, 0.0f, 1.0f) * float(n - 1);
        uint3 lo = uint3(p), hi = min(lo + 1, uint3(n - 1));
        float3 f = p - float3(lo);
        uint a, b, c;
        if (f.x >= f.y) {
            if (f.y >= f.z) { a = 0; b = 1; c = 2; }
            else if (f.x >= f.z) { a = 0; b = 2; c = 1; }
            else { a = 2; b = 0; c = 1; }
        } else {
            if (f.x >= f.z) { a = 1; b = 0; c = 2; }
            else if (f.y >= f.z) { a = 1; b = 2; c = 0; }
            else { a = 2; b = 1; c = 0; }
        }
        uint3 corner = lo;
        float3 v0 = table[(corner.z * n + corner.y) * n + corner.x].xyz;
        corner[a] = hi[a];
        float3 v1 = table[(corner.z * n + corner.y) * n + corner.x].xyz;
        corner[b] = hi[b];
        float3 v2 = table[(corner.z * n + corner.y) * n + corner.x].xyz;
        float3 v3 = table[(hi.z * n + hi.y) * n + hi.x].xyz;
        return v0 * (1 - f[a]) + v1 * (f[a] - f[b]) + v2 * (f[b] - f[c]) + v3 * f[c];
    }

    float3 inputPoint(uint id, constant CloudUniforms &u) {
        uint n = u.grid.x;
        if (u.grid.w) return float3(float(id) / 64);
        if (u.grid.y == 0) return float3(id % n, (id / n) % n, id / (n * n)) / float(n - 1);
        if (u.grid.y == 1) {
            const float3 rays[] = {float3(1,0,0), float3(0,1,0), float3(0,0,1),
                                  float3(0,1,1), float3(1,0,1), float3(1,1,0), float3(1)};
            return rays[id / 65] * (float(id % 65) / 64);
        }
        float x = float(id % n) / float(n - 1), y = float(id / n) / float(n - 1);
        if (u.grid.z == 0) return float3(u.transform.x, x, y);
        if (u.grid.z == 1) return float3(x, u.transform.x, y);
        return float3(x, y, u.transform.x);
    }

    bool inRegion(float3 p, uint region) {
        switch (region) {
            case 1: return p.x >= p.y && p.x >= p.z;
            case 2: return p.y >= p.x && p.y >= p.z;
            case 3: return p.z >= p.x && p.z >= p.y;
            case 4: return p.y >= p.x && p.z >= p.x;
            case 5: return p.x >= p.y && p.z >= p.y;
            case 6: return p.x >= p.z && p.y >= p.z;
            default: return true;
        }
    }

    kernel void generateLUTPointCloud(constant CloudUniforms &u [[buffer(0)]],
                                   device const float4 *table [[buffer(1)]],
                                   device float4 *positions [[buffer(2)]],
                                   device float4 *colors [[buffer(3)]],
                                   device float4 *vectors [[buffer(4)]],
                                   device atomic_uint *counts [[buffer(5)]],
                                   uint id [[thread_position_in_grid]],
                                   uint lane [[thread_index_in_simdgroup]]) {
        bool valid = id < u.options.w;
        bool visible = false, clipped = false;
        if (valid) {
            float3 input = inputPoint(id, u);
            float3 output = sampleLUT(input, u.grid.x, table);
            const float epsilon = 0.5f / 255;
            bool atLimit = any((output <= epsilon) & (input > epsilon)) ||
                           any((output >= 1 - epsilon) & (input < 1 - epsilon)) ||
                           any(output < 0) || any(output > 1);
            bool region = inRegion(input, u.options.x);
            clipped = region && atLimit;
            visible = region && !(u.options.y == 2 && atLimit);
            // Hidden points cannot write depth; vectors collapse to a point outside the camera range.
            float3 position = visible ? clamp(output, -10.0f, 10.0f) - 0.5f : float3(1e6f);
            float3 rgb = clamp(output, 0.0f, 1.0f);
            if (u.options.y == 1) {
                if (atLimit) {
                    if (max(rgb.x, max(rgb.y, rgb.z)) < 0.05f) rgb = input;
                    rgb /= max(max(rgb.x, max(rgb.y, rgb.z)), 0.0001f);
                } else { rgb *= 0.18f; }
            }
            positions[id] = float4(position, 1);
            colors[id] = float4(rgb, visible ? 1.0f : 0.0f);
            if (u.options.z) {
                vectors[id * 2] = float4(visible ? input - 0.5f : position, 1);
                vectors[id * 2 + 1] = float4(position, 1);
            }
        }
        // One atomic per SIMD group rather than one contended atomic per point.
        uint visibleCount = simd_sum(uint(visible));
        uint clippedCount = simd_sum(uint(clipped));
        if (lane == 0) {
            atomic_fetch_add_explicit(counts, visibleCount, memory_order_relaxed);
            atomic_fetch_add_explicit(counts + 1, clippedCount, memory_order_relaxed);
        }
    }
    """
}

#endif
