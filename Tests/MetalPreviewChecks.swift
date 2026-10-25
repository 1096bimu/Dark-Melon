import CoreImage
import Metal
@testable import Dark_Melon

@main struct MetalPreviewChecks {
    @MainActor static func main() async throws {
        let device = MTLCreateSystemDefaultDevice()!
        for space in ProcessingColorSpace.allCases {
            let context = CIContext(mtlDevice: device, options: [.workingColorSpace: space.linear, .workingFormat: CIFormat.RGBAf])
            let input = CIImage(color: CIColor(red: 0.15, green: 0.25, blue: 0.35)).cropped(to: CGRect(x:0,y:0,width:12,height:6))
                .composited(over: CIImage(color: CIColor(red: 0.5, green: 0.4, blue: 0.3)).cropped(to:CGRect(x:0,y:0,width:12,height:12)))
            let source = context.createCGImage(input, from:input.extent,format:.RGBAh,colorSpace:space.linear)!
            let worker = RAWDeveloper(colorSpace:space,interactive:true)
            var mapping = ToneMapping(); mapping.hdrGain = 2
            let pair = try await worker.previews(source,mapping:mapping)
            for (surface,bitmap) in [(pair.surfaceSDR!,pair.sdr),(pair.surfaceHDR!,pair.hdr)] {
                let reference = try await worker.preview(source, mapping: mapping, hdr: surface.hdr)
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba32Float,width:12,height:12,mipmapped:false)
                d.storageMode = .shared; d.usage = [.shaderRead,.shaderWrite,.renderTarget]
                let texture = device.makeTexture(descriptor:d)!
                let image = surface.image
                let command = device.makeCommandQueue()!.makeCommandBuffer()!
                context.render(image,to:texture,commandBuffer:command,bounds:input.extent,colorSpace:space.linear)
                await withCheckedContinuation { continuation in
                    command.addCompletedHandler { _ in continuation.resume() }
                    command.commit()
                }
                var pixels = [Float](repeating:0,count:12*12*4)
                texture.getBytes(&pixels,bytesPerRow:12*16,from:MTLRegionMake2D(0,0,12,12),mipmapLevel:0)
                let sampler = ScopeHoverSampler()
                for y in [2,9] {
                    let rgb = try await sampler.sampleRGB(bitmap,revision:UUID(),position:CGPoint(x:0.5,y:Double(y)/12),space:space)!
                    let referenceRGB = try await sampler.sampleRGB(reference,revision:UUID(),position:CGPoint(x:0.5,y:Double(y)/12),space:space)!
                    for c in 0..<3 { assert(abs(rgb[c]-referenceRGB[c]) < 0.012, "Cached texture changed pixel orientation/color") }
                    let offset = (y*12+6)*4
                    for c in 0..<3 { assert(abs(Double(pixels[offset+c])-rgb[c]) < 0.012,"GPU/bitmap mismatch: \(space), \(surface.hdr), \(y)") }
                }
            }
        }
        print("PASS: direct Metal SDR/HDR graphs match bitmap previews in all working spaces, including vertical orientation")
    }
}
