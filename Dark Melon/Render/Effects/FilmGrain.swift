import CoreImage
import Foundation

nonisolated struct FilmGrainSettings: Codable, Equatable, Sendable {
    enum Output: String, Codable, Sendable {
        case additive, filmDensity
    }

    var size = 2.0
    var strength = 0.0
    var offset = 0.0
    var colorScale = 0.5
    var output = Output.additive

    var isEnabled: Bool { strength > 0 || output == .filmDensity }

    static func defaultSize(for sourceSize: CGSize?) -> Double {
        guard let sourceSize, sourceSize.width.isFinite, sourceSize.height.isFinite,
              sourceSize.width > 0, sourceSize.height > 0 else { return 2 }
        return (min(sourceSize.width, sourceSize.height) / 2000).clamped(to: AdjustmentLimits.grainSize)
    }

    private enum CodingKeys: String, CodingKey { case size, strength, offset, colorScale, output }
    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        strength = try values.decodeIfPresent(Double.self, forKey: .strength) ?? 0
        output = try values.decodeIfPresent(Output.self, forKey: .output) ?? .additive
        // Legacy grain inherits only the saved amount, without rescaling it.
        // Its former size/distribution use incompatible units and are retired.
        guard values.contains(.offset) || values.contains(.colorScale) || values.contains(.output) else { return }
        size = try values.decodeIfPresent(Double.self, forKey: .size) ?? 2
        offset = try values.decodeIfPresent(Double.self, forKey: .offset) ?? 0
        colorScale = try values.decodeIfPresent(Double.self, forKey: .colorScale) ?? 0.5
    }
}

/// Source-linear Gaussian grain. Spatial shaping and luminance/chroma separation
/// happen entirely on the GPU, before the shared SDR/HDR tone pipeline.
nonisolated final class FilmGrain {
    static let defaultFog = 0.0025
    private enum GrainError: LocalizedError {
        case kernel
        var errorDescription: String? { String(localized: "Unable to create the Film Grain processing kernels.") }
    }
    private struct FieldKey: Equatable {
        var seed: UInt32
        var scale: Double
        var analogue: Bool
    }
    private var fieldCache: (FieldKey, CIImage, CIImage, CIImage)?
    private let noise: CIKernel
    private let moments: CIKernel
    private let finish: CIKernel
    private let response: CIColorKernel

    /// Stable across launches; independent of Swift's randomized Hasher and edit metadata.
    static func seed(for url: URL) -> UInt32 {
        url.standardizedFileURL.path.utf8.reduce(UInt32(2166136261)) { ($0 ^ UInt32($1)) &* 16777619 } & 0x00ffffff
    }

    private static let source = """
    #include <metal_stdlib>
    #include <CoreImage/CoreImage.h>
    using namespace metal;
    extern "C" { namespace coreimage {
    // PCG RXS-M-XS hash; Jarzynski & Olano, Hash Functions for GPU Rendering.
    // https://jcgt.org/published/0009/03/02/
    uint grainHash(uint value) {
        uint state=value*747796405u+2891336453u;
        uint word=((state>>((state>>28u)+4u))^state)*277803737u;
        return (word>>22u)^word;
    }
    float gaussianNoise(uint2 p, uint seed) {
        uint h=grainHash(p.x^grainHash(p.y^seed));
        float u=(float(h>>8u)+0.5)/16777216.0;
        float v=(float(grainHash(h^0x9e3779b9u)>>8u)+0.5)/16777216.0;
        return sqrt(-2.0*log(u))*cos(6.28318530718*v);
    }
    float3 colorBand(float3 band, float colorWeight, float3 luminanceWeights) {
        float luminance=dot(band,luminanceWeights);
        return mix(float3(luminance),band,colorWeight);
    }
    float3 filmDensity(float3 exposure, float3 slopes, float fog) {
        float3 e=max(exposure,0.0);
        float3 neutral=e/(e+4.0);
        // Tilt the same saturating density curve in log exposure. All layer
        // curves share fog, midpoint (E=4), and density range.
        float3 h=log(max(e,float3(1e-30))/4.0);
        float3 shaped=1.0/(1.0+exp(-clamp(h*slopes,-80.0,80.0)));
        shaped=select(float3(0.0),shaped,e>0.0);
        return fog+4.0*select(shaped,neutral,slopes==1.0);
    }
    float3 filmPositive(float3 density) {
        // Adaptive fog can be far below one float ULP around 1. Avoid losing
        // it to cancellation in 1-exp(-D), which later brightening magnifies.
        float3 small=density*(1.0-density*(0.5-density/6.0));
        return select(1.0-exp(-density),small,density<0.001);
    }
    float3 filmExposure(float3 rgb, float3 a0, float3 a1, float3 a2) {
        return max(float3(dot(a0,rgb),dot(a1,rgb),dot(a2,rgb)),0.0);
    }
    float3 filmOutput(float3 exposed, float3 unit, float strength, float offset, float analogue, float fog,
                      float3 slopes, float3 purity, float3 b0, float3 b1, float3 b2) {
        float3 developed;
        if (analogue>0.5) {
            float3 density=filmDensity(exposed,slopes,fog);
            density=max(density+8.0*strength*0.0008505*sqrt(density)*unit,0.0);
            // Cross-absorption acts on the noisy layers before transmission.
            // Convex mixing preserves neutral density and finite headroom.
            float3 impurity=1.5*(1.0-purity);
            float3 mixed=density+float3(
                0.08*impurity.g*(density.g-density.r)+0.03*impurity.b*(density.b-density.r),
                0.16*impurity.r*(density.r-density.g)+0.10*impurity.b*(density.b-density.g),
                0.06*impurity.r*(density.r-density.b)+0.20*impurity.g*(density.g-density.b));
            developed=filmPositive(max(mixed,0.0));
        } else {
            float3 shifted=unit+3.0*offset;
            float3 oneSided=offset>=0.0 ? max(shifted,0.0):min(shifted,0.0);
            developed=max(exposed+strength*0.0008505*mix(shifted,oneSided,abs(offset)),0.0);
        }
        return max(float3(dot(b0,developed),dot(b1,developed),dot(b2,developed)),0.0);
    }
    [[stitchable]] float4 grainResponse(sample_t picture, float analogue, float fog,
                                      float3 a0, float3 a1, float3 a2, float3 b0, float3 b1, float3 b2,
                                      float3 slopes, float3 purity) {
        float4 color=unpremultiply(picture);
        float3 exposed=filmExposure(color.rgb,a0,a1,a2);
        color.rgb=filmOutput(exposed,float3(0.0),0.0,0.0,analogue,fog,slopes,purity,b0,b1,b2);
        return premultiply(color);
    }
    [[stitchable]] float4 grainWhite(float seed, destination dest) {
        uint2 p=uint2(int2(floor(dest.coord())));
        float red=gaussianNoise(p,uint(seed));
        float3 value=float3(red);
        value.g=gaussianNoise(p,uint(seed)^0x68bc21ebu);
        value.b=gaussianNoise(p,uint(seed)^0x02e5be93u);
        return float4(value,1.0);
    }
    [[stitchable]] float4 grainMoments(sampler white, sampler small, float analogue, destination dest) {
        float2 p=dest.coord();
        float3 a=white.sample(white.transform(p)).rgb;
        float3 b=small.sample(small.transform(p)).rgb;
        // Analogue: (a-b) + 0*(b-c) + 0*c.
        // Digital:  (a-b) + 1*(b-c) + 1*c = a; no broader blurs needed.
        return float4(analogue>0.5 ? a-b:a,1.0);
    }
    [[stitchable]] float4 grainFinish(sampler picture, sampler field, sampler means, sampler squares,
                                    float strength, float offset, float analogue, float fog,
                                    float3 a0, float3 a1, float3 a2, float3 b0, float3 b1, float3 b2,
                                    float3 slopes, float3 purity, float colorScale, float3 luminanceWeights, destination dest) {
        float2 p=dest.coord();
        float3 mean=means.sample(means.transform(float2(0.5))).rgb;
        float3 second=squares.sample(squares.transform(float2(0.5))).rgb;
        float3 variance=max(float3(0.0),second-mean*mean);
        // Normalize the RGB texture before applying simple desaturation.
        variance=float3(dot(variance,float3(1.0/3.0)));
        float3 value=field.sample(field.transform(p)).rgb;
        float3 unit=select(float3(0.0),(value-mean)*rsqrt(max(variance,float3(1e-12))),variance>1e-12);
        unit=colorBand(unit,colorScale,luminanceWeights);
        float4 color=unpremultiply(picture.sample(picture.transform(p)));
        float3 exposed=filmExposure(color.rgb,a0,a1,a2);
        color.rgb=filmOutput(exposed,unit,strength,offset,analogue,fog,slopes,purity,b0,b1,b2);
        return premultiply(color);
    }
    }}
    """

    init() throws {
        // Separate entry points keep Core Image's sampler argument layouts distinct.
        let pieces = Self.source.components(separatedBy: "[[stitchable]]")
        var kernels = [CIKernel]()
        for index in 1..<pieces.count {
            let closing = index == pieces.count - 1 ? "" : "\n}}"
            kernels += try CIKernel.kernels(withMetalString: pieces[0] + "[[stitchable]]" + pieces[index] + closing)
        }
        guard let noise = kernels.first(where: { $0.name == "grainWhite" }),
              let moments = kernels.first(where: { $0.name == "grainMoments" }),
              let finish = kernels.first(where: { $0.name == "grainFinish" }),
              let response = kernels.first(where: { $0.name == "grainResponse" }) as? CIColorKernel else {
            throw GrainError.kernel
        }
        self.noise = noise; self.moments = moments; self.finish = finish
        self.response = response
    }

    func apply(to image: CIImage, settings: FilmGrainSettings, seed: UInt32 = 1,
               luminance: SIMD3<Double> = SIMD3(0.2126, 0.7152, 0.0722), renderScale: Double = 1,
               mixers: DyeMixers = DyeMixers(), slopes: SIMD3<Double> = SIMD3(repeating: 1),
               purity: SIMD3<Double> = SIMD3(repeating: 1), fog: Double = FilmGrain.defaultFog) throws -> CIImage {
        guard settings.isEnabled || !mixers.isIdentity else { return image }
        guard fog.isFinite, (0...Self.defaultFog).contains(fog), mixers.isValid, (0..<3).allSatisfy({ slopes[$0].isFinite && slopes[$0] > 0
            && purity[$0].isFinite && (0...1).contains(purity[$0]) }) else { throw GrainError.kernel }
        let rows = [mixers.a, mixers.b].flatMap { matrix in
            stride(from: 0, to: 9, by: 3).map { i in
                CIVector(x: matrix[i], y: matrix[i + 1], z: matrix[i + 2])
            }
        }
        let model: [Any] = [settings.output == .filmDensity ? 1.0 : 0.0, fog] + rows + [
            CIVector(x: slopes.x, y: slopes.y, z: slopes.z),
            CIVector(x: purity.x, y: purity.y, z: purity.z)]
        let extent = image.extent
        // Zero Strength retains the film response without generating, blurring
        // or reducing a noise field. Additive zero remains an exact bypass.
        if settings.strength <= 0 {
            guard let result = response.apply(extent: extent, arguments: [image] + model) else { throw GrainError.kernel }
            return result
        }
        let size = settings.size.clamped(to: AdjustmentLimits.grainSize)
        // Size is in source pixels. Only preview/detail downsampling changes
        // the rendering scale; image dimensions already set the default Size.
        let scale = size * max(0.000001, renderScale)
        let key = FieldKey(seed: seed & 0x00ffffff, scale: scale,
                           analogue: settings.output == .filmDensity)
        let field: CIImage, mean: CIImage, squares: CIImage
        if let cached = fieldCache, cached.0 == key {
            field = cached.1; mean = cached.2; squares = cached.3
        } else {
            // Infinite procedural fields let detail rendering evaluate only the
            // visible region. No full-resolution noise bitmap is retained.
            guard let white = noise.apply(extent: .infinite, roiCallback: { _, rect in rect },
                                           arguments: [Double(key.seed)]) else { throw GrainError.kernel }
            let small = key.analogue ? white.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.0]) : white
            guard let shaped = moments.apply(extent: .infinite, roiCallback: { _, rect in rect },
                                            arguments: [white, small, key.analogue ? 1.0 : 0.0]) else { throw GrainError.kernel }
            field = shaped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            // Normalize a bounded reference region on the GPU, rather than
            // reducing a 100MP image every time grain controls change.
            let sample = CGRect(x: 0, y: 0, width: 512, height: 512)
            let reference = field.cropped(to: sample).insertingIntermediate(cache: true)
            let area = [kCIInputExtentKey: CIVector(cgRect: sample)]
            mean = reference.applyingFilter("CIAreaAverage", parameters: area).insertingIntermediate(cache: true)
            let square = CIVector(x: 0, y: 0, z: 1, w: 0)
            squares = reference.applyingFilter("CIColorPolynomial", parameters: [
                "inputRedCoefficients": square, "inputGreenCoefficients": square, "inputBlueCoefficients": square
            ]).applyingFilter("CIAreaAverage", parameters: area).insertingIntermediate(cache: true)
            fieldCache = (key, field, mean, squares)
        }
        let softened = image.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: scale / 2])
            .cropped(to: extent)
        guard let result = finish.apply(extent: extent, roiCallback: { index, rect in
            index >= 2 ? mean.extent : rect
        }, arguments: [softened, field, mean, squares,
                       settings.strength.clamped(to: AdjustmentLimits.strength), settings.offset.clamped(to: -1...1)] + model + [
                       settings.colorScale.clamped(to: 0...1),
                       CIVector(x: luminance.x, y: luminance.y, z: luminance.z)]) else {
            throw GrainError.kernel
        }
        return result
    }
}
