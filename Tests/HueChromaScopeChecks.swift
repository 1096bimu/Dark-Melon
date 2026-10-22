import CoreImage
import Metal
import simd
@testable import Dark_Melon

@main struct HueChromaScopeChecks {
    static func main() async throws {
        let worker = try GPUVectorscope()
        for space in ProcessingColorSpace.allCases {
            let context = CIContext(options: [.workingColorSpace: space.linear])
            let matrix = ScopeProjection.matrix(.sRGB).inverse * ScopeProjection.matrix(space)
            for lightnessScale in [0.0,1.0,2.0] {
            for rgb in [SIMD3<Double>(1,0,0), SIMD3(0,1,0), SIMD3(0,0,1), SIMD3(0.5,0.5,0.5)] {
                let image = CIImage(color: CIColor(red: rgb.x, green: rgb.y, blue: rgb.z, colorSpace: space.linear)!)
                    .cropped(to: CGRect(x: 0,y: 0,width: 64,height: 64))
                let source = context.createCGImage(image, from: image.extent, format: .RGBAh, colorSpace: space.linear)!
                let frame = try await worker.render(source: source, mapping: ToneMapping(), space: space, zoom: -2, hueChroma: true, lightnessScale:lightnessScale)
                let texture = frame.texture
                let device = texture.device
                let buffer = device.makeBuffer(length: 513*513*4, options: .storageModeShared)!
                let command = device.makeCommandQueue()!.makeCommandBuffer()!
                let blit = command.makeBlitCommandEncoder()!
                blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                    sourceSize: MTLSize(width: 513,height: 513,depth: 1), to: buffer, destinationOffset: 0,
                    destinationBytesPerRow: 513*4,destinationBytesPerImage: 513*513*4)
                blit.endEncoding()
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    command.addCompletedHandler { _ in continuation.resume() }
                    command.commit()
                }
                let bytes = buffer.contents().assumingMemoryBound(to: UInt8.self)
                let lit = (0..<513*513).filter { bytes[$0*4] > 0 }
                let lab = OKLabVertexWarp.lab(matrix*rgb)
                let chroma = hypot(lab.y,lab.z)
                if chroma < 0.00001 { assert(lit.isEmpty); continue }
                var h = atan2(lab.z,lab.y)/(2 * .pi)
                if h < 0 { h += 1 }
                let ordinate = lightnessScale > 0 ? lab.x/lightnessScale : chroma*2
                let expectedX = Int(h*513), expectedY = Int(((1-ordinate)*512).rounded())
                assert(!lit.isEmpty)
                assert(lit.allSatisfy { abs($0%513-expectedX)<=2 && abs($0/513-expectedY)<=2 })
            }
        }
        }
        // A mode switch may replace the CGImage without changing the preview revision.
        let sampler=ScopeHoverSampler()
        let revision=UUID()
        let context=CIContext()
        for value in [0.25,0.75] {
            let image=CIImage(color:CIColor(red:value,green:0,blue:0,colorSpace:ProcessingColorSpace.sRGB.linear)!).cropped(to:CGRect(x:0,y:0,width:2,height:2))
            let source=context.createCGImage(image,from:image.extent,format:.RGBAf,colorSpace:ProcessingColorSpace.sRGB.linear)!
            let sample=try await sampler.sampleRGB(source,revision:revision,position:CGPoint(x:0.5,y:0.5),space:.sRGB)!
            assert(abs(sample.x-value)<0.0001)
        }
        print("GPU hue/chroma and hue/lightness bins, HDR scale, neutral omission, and hover source replacement passed.")
    }
}
