import Foundation
import CoreImage
@testable import Dark_Melon

@main struct OKLabSDRBrightnessChecks {
    static func main() async throws {
        let inputs: [SIMD3<Float>] = [
            SIMD3(repeating: 0.65), SIMD3(1.773, 0.6696, 0.3906),
            SIMD3(1.97, 0.744, 0.434), SIMD3(1.4, 0.73, 0.68),
            SIMD3(-0.1, 0.65, 0.5), SIMD3(0.02, 0.2, 0.8), SIMD3(repeating: 1)
        ]
        var chroma = ColorAdjustments(); chroma.saturationMid = 1.000001
        var lightness = ColorAdjustments(); lightness.luminanceSaturationEnd = 0.999999
        var hdrOnly = ColorAdjustments(); hdrOnly.saturationHDR = 1.000001
        var tint = ColorAdjustments(); tint.splitTone.nodes = [SplitToneNode(lightness: 0.5, hue: 30, strength: 1e-8)]
        var zeroTint = ColorAdjustments(); zeroTint.splitTone.nodes = [SplitToneNode(lightness: 0.5, hue: 30, strength: 0)]
        var vertices = OKLabVertexWarp.defaults; vertices[0].lightness = 1e-8
        let cases: [(String, ColorAdjustments, [OKLabVertexAdjustment])] = [
            ("chroma", chroma, OKLabVertexWarp.defaults),
            ("lightness chroma", lightness, OKLabVertexWarp.defaults),
            ("HDR-only chroma", hdrOnly, OKLabVertexWarp.defaults),
            ("tiny split tone", tint, OKLabVertexWarp.defaults),
            ("zero split tone", zeroTint, OKLabVertexWarp.defaults),
            ("tiny vertex", ColorAdjustments(), vertices)
        ]
        for space in ProcessingColorSpace.allCases {
            let context = CIContext(options: [.workingColorSpace: space.linear, .workingFormat: CIFormat.RGBAf])
            let pipeline = OKLabColorPipeline()
            func image(_ colors: [SIMD3<Float>]) -> CIImage {
                let pixels: [Float] = colors.flatMap { [$0.x, $0.y, $0.z, Float(1)] }
                return CIImage(bitmapData: pixels.withUnsafeBytes { Data($0) }, bytesPerRow: pixels.count * 4,
                               size: CGSize(width: colors.count, height: 1), format: .RGBAf, colorSpace: space.linear)
            }
            func pixels(_ image: CIImage) -> [Float] {
                var result = [Float](repeating: 0, count: Int(image.extent.width * image.extent.height) * 4)
                context.render(image, toBitmap: &result, rowBytes: Int(image.extent.width) * 16,
                               bounds: image.extent, format: .RGBAf, colorSpace: space.linear)
                return result
            }
            func bounded(_ image: CIImage) -> CIImage {
                image.applyingFilter("CIColorClamp", parameters: [
                    "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
            }
            let source = image(inputs), expected = pixels(bounded(source))
            for (name, color, controls) in cases {
                for domain in [1.0, 8] {
                    let output = try pipeline.apply(source, color: color, vertices: controls,
                                                    space: space, ceiling: 1, domainCeiling: domain)
                    precondition(zip(pixels(bounded(output)), expected).allSatisfy { abs($0-$1) < 0.00002 },
                                 "SDR brightness changed: \(space), \(name), domain \(domain)")
                }
                // Extended RGB below the HDR ceiling must remain extended.
                let hdrSource = image(inputs.filter { $0.min() >= 0 })
                let hdr = try pipeline.apply(hdrSource, color: color, vertices: controls,
                                             space: space, ceiling: 8, domainCeiling: 8)
                precondition(zip(pixels(hdr), pixels(hdrSource)).allSatisfy { abs($0-$1) < 0.00002 },
                             "HDR brightness changed: \(space), \(name)")
            }
            // Exercise the full renderer: tone -> RGB white balance -> OKLab ->
            // separate SDR/HDR previews, including the interactive texture path.
            for interactive in [false, true] {
                let worker = RAWDeveloper(colorSpace: space, interactive: interactive)
                let neutral = image([SIMD3(repeating: 0.65)])
                let bitmap = context.createCGImage(neutral, from: neutral.extent, format: .RGBAh, colorSpace: space.linear)!
                var mapping = ToneMapping.fresh(isRAW: false, sourceHeadroom: 1)
                mapping.tonePosition = 0.65; mapping.hdrGain = 1; mapping.hdrTarget = 8
                mapping.whiteBalance.red = 1.97; mapping.whiteBalance.green = 0.744; mapping.whiteBalance.blue = 0.434
                let before = try await worker.previews(bitmap, mapping: mapping)
                mapping.color = chroma
                let after = try await worker.previews(bitmap, mapping: mapping)
                for (a, b, tolerance) in [(before.sdr, after.sdr, Float(0.009)), (before.hdr, after.hdr, Float(0.003))] {
                    precondition(zip(pixels(CIImage(cgImage: a)), pixels(CIImage(cgImage: b))).allSatisfy { abs($0-$1) < tolerance })
                }
                if !interactive {
                    var settings = HEIFSettings(); settings.format = .tiff; settings.tiff16Bit = true; settings.tiffHDR = false
                    mapping.color = ColorAdjustments()
                    let baseline = try await worker.exportImage(CIImage(cgImage: bitmap), mapping: mapping, settings: settings)
                    mapping.color = chroma
                    let edited = try await worker.exportImage(CIImage(cgImage: bitmap), mapping: mapping, settings: settings)
                    precondition(zip(pixels(CIImage(data: baseline)!), pixels(CIImage(data: edited)!)).allSatisfy { abs($0-$1) < 0.0002 })
                }
                if interactive {
                    let size = CGSize(width: 12012, height: 8719)
                    let large = CIImage(color: CIColor(red: 0.65, green: 0.65, blue: 0.65, colorSpace: space.linear)!)
                        .cropped(to: CGRect(origin: .zero, size: size))
                    let development = RAWDevelopment(preview: bitmap, linearSource: large,
                        url: URL(fileURLWithPath: "/tmp/oklab-large-synthetic"), width: 12012, height: 8719,
                        whitePoint: nil, metadata: CameraMetadata(properties: [:]), isRAW: false,
                        rawDefaults: nil, sourceHeadroom: 1)
                    let region = PreviewRegion(rect: CGRect(x: 0.4, y: 0.4, width: 0.01, height: 0.01), displayPixels: size)
                    for hdr in [false, true] {
                        mapping.color = ColorAdjustments()
                        let baseline = try await worker.detail(development, mapping: mapping, hdr: hdr, region: region)
                        mapping.color = chroma
                        let edited = try await worker.detail(development, mapping: mapping, hdr: hdr, region: region)
                        let tolerance: Float = hdr ? 0.003 : 0.009
                        precondition(zip(pixels(CIImage(cgImage: baseline.image)), pixels(CIImage(cgImage: edited.image))).allSatisfy { abs($0-$1) < tolerance })
                    }
                }
            }
        }
        print("PASS: SDR over-white/negative RGB, near-neutral OKLab controls, three gamuts, HDR preservation, RGB-WB previews, 105 MP detail coordinates, TIFF exports and interactive textures")
    }
}
