import Foundation
import CoreImage
import simd
@testable import Dark_Melon

@main struct BlueGamutChecks {
    static func rgb(_ lab: SIMD3<Double>) -> SIMD3<Double> {
        let l = pow(lab.x + 0.3963377774*lab.y + 0.2158037573*lab.z, 3)
        let m = pow(lab.x - 0.1055613458*lab.y - 0.0638541728*lab.z, 3)
        let s = pow(lab.x - 0.0894841775*lab.y - 1.2914855480*lab.z, 3)
        return SIMD3(4.0767416621*l - 3.3077115913*m + 0.2309699292*s,
                     -1.2684380046*l + 2.6097574011*m - 0.3413193965*s,
                     -0.0041960863*l - 0.7034186147*m + 1.7076147010*s)
    }
    static func main() throws {
        let pipeline = OKLabColorPipeline()
        var worst = 0.0
        for space in ProcessingColorSpace.allCases {
            let to = ScopeProjection.matrix(.sRGB).inverse * ScopeProjection.matrix(space)
            let context = CIContext(options: [.workingColorSpace: space.linear, .workingFormat: CIFormat.RGBAf])
            for ceiling in [1.0, 8.0] {
                for mode in 1...2 {
                    let color = ColorAdjustments()
                    var vertices = Array(repeating: OKLabVertexAdjustment(), count: 7)
                    vertices[5].rotation = mode == 1 ? -1 : 1
                    for lightness in [0.3, 0.4, 0.45, 0.5, 0.6] {
                        var pixels = [Float]()
                        for i in 0...3000 {
                            let h = (250 + Double(i)*0.01) * .pi/180
                            let v = to.inverse * rgb(SIMD3(lightness, 0.35*cos(h), 0.35*sin(h))) * ceiling
                            pixels += [Float(v.x), Float(v.y), Float(v.z), 1]
                        }
                        let count = pixels.count/4
                        let image = CIImage(bitmapData: pixels.withUnsafeBytes { Data($0) }, bytesPerRow: count*16,
                            size: CGSize(width: count, height: 1), format: .RGBAf, colorSpace: space.linear)
                        let output = try pipeline.apply(image, color: color, vertices: vertices,
                            space: space, ceiling: ceiling, domainCeiling: ceiling)
                        context.render(output, toBitmap: &pixels, rowBytes: count*16, bounds: image.extent,
                            format: .RGBAf, colorSpace: space.linear)
                        var previous: SIMD3<Double>?
                        for i in stride(from: 0, to: pixels.count, by: 4) {
                            let v = SIMD3(Double(pixels[i]), Double(pixels[i+1]), Double(pixels[i+2]))
                            assert(v.min() >= -0.00001 && v.max() <= ceiling+0.00001)
                            assert(pixels[i+3] == 1)
                            let lab = OKLabVertexWarp.lab(to*v/ceiling)
                            if let previous {
                                let jump = simd_length(lab-previous)
                                worst = max(worst, jump)
                                assert(jump < 0.002, "Deep-blue discontinuity: \(jump)")
                            }
                            previous = lab
                        }
                    }
                }
            }
        }
        print("Blue gamut sweeps passed: three gamuts, SDR/HDR, ±blue rotation. Max adjacent OKLab change: \(worst)")
    }
}
