import SwiftUI
import MetalKit

#if os(macOS)
struct ScopeMetalView: NSViewRepresentable {
    let frame: ScopeTexture
    func makeNSView(context: Context) -> ScopeDisplay { ScopeDisplay() }
    func updateNSView(_ view: ScopeDisplay, context: Context) { view.display(frame) }
}
#else
struct ScopeMetalView: UIViewRepresentable {
    let frame: ScopeTexture
    func makeUIView(context: Context) -> ScopeDisplay { ScopeDisplay() }
    func updateUIView(_ view: ScopeDisplay, context: Context) { view.display(frame) }
}
#endif

final class ScopeDisplay: MTKView, MTKViewDelegate {
    private var image: MTLTexture?
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?

    init() {
        super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())
        isPaused = true
        enableSetNeedsDisplay = false
        preferredFramesPerSecond = 60
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0, 0, 0, 1)
        delegate = self
        queue = device?.makeCommandQueue()
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct Vertex { float4 position [[position]]; float2 uv; };
        vertex Vertex scopeVertex(uint id [[vertex_id]]) {
            float2 uv = float2((id << 1) & 2, id & 2);
            return {float4(uv.x * 2 - 1, 1 - uv.y * 2, 0, 1), uv};
        }
        fragment float4 scopeFragment(Vertex v [[stage_in]], texture2d<float> image [[texture(0)]]) {
            constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::nearest);
            return image.sample(s, v.uv);
        }
        """
        if let library = try? device?.makeLibrary(source: source, options: nil) {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "scopeVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "scopeFragment")
            descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
            pipeline = try? device?.makeRenderPipelineState(descriptor: descriptor)
        }
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func display(_ frame: ScopeTexture) { image = frame.texture; draw() }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { draw() }
    func draw(in view: MTKView) {
        guard let image, let pipeline, let drawable = currentDrawable,
              let pass = currentRenderPassDescriptor, let command = queue?.makeCommandBuffer(),
              let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(image, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        command.present(drawable)
        command.commit()
    }
}
