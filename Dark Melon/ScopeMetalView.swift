import SwiftUI
import MetalKit

#if os(macOS)
struct ScopeMetalView: NSViewRepresentable {
    let frame: ScopeTexture
    var gradient: ScopeGradient? = nil
    func makeNSView(context: Context) -> ScopeDisplay { ScopeDisplay() }
    func updateNSView(_ view: ScopeDisplay, context: Context) { view.display(frame, gradient: gradient) }
}
#else
struct ScopeMetalView: UIViewRepresentable {
    let frame: ScopeTexture
    var gradient: ScopeGradient? = nil
    func makeUIView(context: Context) -> ScopeDisplay { ScopeDisplay() }
    func updateUIView(_ view: ScopeDisplay, context: Context) { view.display(frame, gradient: gradient) }
}
#endif

final class ScopeDisplay: MTKView, MTKViewDelegate {
    private var image: MTLTexture?
    private var palette: MTLTexture?
    private var paletteGradient: ScopeGradient?
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?

    init() {
        super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())
        isPaused = true
        enableSetNeedsDisplay = true
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
        fragment float4 scopeFragment(Vertex v [[stage_in]], texture2d<float> image [[texture(0)]], texture2d<float> palette [[texture(1)]]) {
            constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::nearest);
            float value=image.sample(s,v.uv).r;
            constexpr sampler colors(coord::normalized,address::clamp_to_edge,filter::linear);
            return value<=0.0 ? float4(0,0,0,1) : palette.sample(colors,float2((value*255.0+0.5)/256.0,0.5));
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
    func display(_ frame: ScopeTexture, gradient: ScopeGradient? = nil) {
        if palette == nil || gradient != paletteGradient {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                width: 256, height: 1, mipmapped: false)
            descriptor.usage = .shaderRead
            descriptor.storageMode = .shared
            palette = device?.makeTexture(descriptor: descriptor)
            var bytes = [UInt8]()
            for i in 0...255 {
                let rgb = gradient?.rgb(at: Float(i)/255) ?? (r: UInt8(i), g: UInt8(i), b: UInt8(i))
                bytes += [rgb.r, rgb.g, rgb.b, 255]
            }
            bytes.withUnsafeBytes { data in
                palette?.replace(region: MTLRegionMake2D(0, 0, 256, 1), mipmapLevel: 0,
                                 withBytes: data.baseAddress!, bytesPerRow: 1024)
            }
            paletteGradient = gradient
        }
        image = frame.texture
        requestDisplay()
    }

    private func requestDisplay() {
        #if os(macOS)
        needsDisplay = true
        #else
        setNeedsDisplay()
        #endif
    }

    #if os(macOS)
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        requestDisplay()
    }
    #else
    override func didMoveToWindow() {
        super.didMoveToWindow()
        requestDisplay()
    }
    #endif

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { requestDisplay() }
    func draw(in view: MTKView) {
        guard let image, let palette, let pipeline, let drawable = currentDrawable,
              let pass = currentRenderPassDescriptor, let command = queue?.makeCommandBuffer(),
              let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(image, index: 0)
        encoder.setFragmentTexture(palette, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        command.present(drawable)
        command.commit()
    }
}
