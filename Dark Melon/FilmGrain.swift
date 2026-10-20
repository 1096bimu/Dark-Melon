import CoreImage
import Foundation

nonisolated struct FilmGrainSettings: Codable, Equatable, Sendable {
    var size = 0.5
    var strength = 0.0
    var distribution = 0.0

    /// Peak-normalized envelope over source-linear luminance: shadow peak at zero, midtone peak at one.
    func weight(at tone: Double) -> Double {
        let x = min(1, max(0, tone)), peak = distribution.clamped(to: 0...1) * 0.5
        if peak == 0 { return pow(1 - x, 4) }
        if x == 0 || x == 1 { return 0 }
        return exp(4 * peak * log(x / peak) + 4 * (1 - peak) * log((1 - x) / (1 - peak)))
    }
}

// Adapted from mr-berndt/cinegrain2, e4b27ad4cb5b1a6695b53e938e4b17e60e60fa32.
// Copyright (C) 2026 mr-berndt. GPL-3.0-or-later; see Cinegrain2-LICENSE.txt.
// Uses the current difference-of-Gaussians grain shape, with a fixed still-image
// seed and a one-parameter tonal envelope instead of the upstream five-zone EQ.
nonisolated final class FilmGrain {
    private enum GrainError: LocalizedError {
        case kernel
        var errorDescription: String? { String(localized: "Unable to create the Film Grain processing kernels.") }
    }
    private let noise: CIKernel
    private let downsample: CIKernel
    private let blur: CIKernel
    private let finish: CIKernel

    private static let source = """
    #include <metal_stdlib>
    #include <CoreImage/CoreImage.h>
    using namespace metal;
    extern "C" { namespace coreimage {
    float grainHash(float2 p) {
        float sum = 0.0;
        for (int i=0; i<4; ++i) {
            float3 q = fract(float3(p.x,p.y,p.x)*float3(0.1031,0.1030,0.0973)+0.314159+float(i)*7.31);
            q += dot(q,q.yzx+33.33);
            sum += fract((q.x+q.y)*q.z);
        }
        return sum-2.0;
    }
    [[stitchable]] float4 filmNoise(destination dest) {
        float2 p = floor(dest.coord())+0.5;
        float3 n = float3(grainHash(p+float2(137,-73)), grainHash(p), grainHash(p+float2(-82,235)));
        return float4(n*0.25+0.5,1);
    }
    [[stitchable]] float4 filmDownsample(sampler field, destination dest) {
        float2 p = dest.coord()*4.0;
        return (field.sample(field.transform(p+float2(-1,-1)))+
                field.sample(field.transform(p+float2(1,-1)))+
                field.sample(field.transform(p+float2(-1,1)))+
                field.sample(field.transform(p+float2(1,1))))*0.25;
    }
    [[stitchable]] float4 filmBlur(sampler field, float sigma, float2 axis, float maximumRadius, destination dest) {
        float2 p = dest.coord();
        if (sigma<0.05) return field.sample(field.transform(p));
        int radius = int(min(ceil(2.5*sigma),maximumRadius));
        float3 sum=field.sample(field.transform(p)).rgb;
        float total=1.0;
        for (int i=1; i<=16; ++i) {
            if (i>radius) break;
            float w=exp(-0.5*float(i*i)/(sigma*sigma));
            float2 d=axis*float(i);
            sum += (field.sample(field.transform(p-d)).rgb+field.sample(field.transform(p+d)).rgb)*w;
            total += 2*w;
        }
        return float4(sum/total,1);
    }
    [[stitchable]] float4 filmApply(sampler picture, sampler source, sampler narrow, sampler wide,
                                    float4 parameters, float3 weights, float ceiling, destination dest) {
        float2 p=dest.coord();
        float4 color=unpremultiply(picture.sample(picture.transform(p)));
        float3 n=(narrow.sample(narrow.transform(p)).rgb-0.5)*4.0;
        float3 w=(wide.sample(wide.transform(p)).rgb-0.5)*4.0;
        float3 unit=(n-0.95*w)*parameters.x;
        float grain=dot(unit,float3(0.2126,0.7152,0.0722));
        // Use decoded source-linear luminance, independent of SDR/HDR development.
        float3 input=unpremultiply(source.sample(source.transform(p))).rgb;
        float t=clamp(dot(input,weights),0.0,1.0);
        float peak=parameters.w*0.5;
        float envelope=0.0;
        if (peak<=0.000001) envelope=pow(1-t,4.0);
        else if (t>0 && t<1) envelope=exp(4*peak*log(t/peak)+4*(1-peak)*log((1-t)/(1-peak)));
        float gain=exp(parameters.y*parameters.z*envelope*grain);
        color.rgb=clamp(color.rgb*gain,0.0,ceiling);
        return premultiply(color);
    }
    }}
    """

    init() throws {
        // Compile each entry point separately so Core Image keeps its argument layout distinct.
        let parts = Self.source.components(separatedBy: "[[stitchable]]")
        var kernels: [CIKernel] = []
        for index in 1..<parts.count {
            let closing = index == parts.count - 1 ? "" : "\n}}"
            kernels += try CIKernel.kernels(withMetalString: parts[0] + "[[stitchable]]" + parts[index] + closing)
        }
        guard let noise = kernels.first(where: { $0.name == "filmNoise" }),
              let downsample = kernels.first(where: { $0.name == "filmDownsample" }),
              let blur = kernels.first(where: { $0.name == "filmBlur" }),
              let finish = kernels.first(where: { $0.name == "filmApply" }) else { throw GrainError.kernel }
        self.noise = noise; self.downsample = downsample; self.blur = blur; self.finish = finish
    }

    func apply(to image: CIImage, source: CIImage, settings: FilmGrainSettings,
               weights: SIMD3<Double>, ceiling: Double) throws -> CIImage {
        guard settings.strength > 0 else { return image }
        let extent = image.extent.integral
        let shortSide = min(extent.width, extent.height)
        let size = settings.size.clamped(to: 0.2...3)
        let resolutionScale = EffectResolution.scale(shortSide: shortSide)
        let grainReferenceRadius = size * EffectResolution.referenceShortSide / 2160
        let sigma = max(grainReferenceRadius * resolutionScale, 0.05)
        // A 6000 × 4000 image uses radius = Size × 1. Scale with the
        // shorter dimension, just like grain, while keeping its existing size unchanged.
        let baseBlurMultiplier = 1.0
        let baseBlurRadius = size * baseBlurMultiplier * resolutionScale
        let softened = image.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: baseBlurRadius])
            .cropped(to: image.extent)
        let wideSigma = sqrt(max(pow(8.4*sigma,2)-3.92,0))/4
        // Overscan avoids finite-image borders in the procedural field.
        let padded = extent.insetBy(dx: -80, dy: -80)
        guard let field = noise.apply(extent: padded, roiCallback: { _, rect in rect }, arguments: []) else {
            throw GrainError.kernel
        }
        func gaussian(_ image: CIImage, sigma: Double, maxRadius: Double) throws -> CIImage {
            guard sigma >= 0.05 else { return image }
            let radius = min(ceil(2.5*sigma),maxRadius)
            guard let horizontal = blur.apply(extent: image.extent,
                roiCallback: { _, rect in rect.insetBy(dx: -radius, dy: 0) },
                arguments: [image, sigma, CIVector(x: 1,y: 0), maxRadius]),
                  let vertical = blur.apply(extent: image.extent,
                roiCallback: { _, rect in rect.insetBy(dx: 0, dy: -radius) },
                arguments: [horizontal, sigma, CIVector(x: 0,y: 1), maxRadius]) else { throw GrainError.kernel }
            return vertical
        }
        let narrow = try gaussian(field, sigma: sigma, maxRadius: 8)
        let quarterExtent = padded.applying(CGAffineTransform(scaleX: 0.25,y: 0.25)).integral
        guard let quarter = downsample.apply(extent: quarterExtent,
            roiCallback: { _, rect in rect.applying(CGAffineTransform(scaleX: 4,y: 4)).insetBy(dx: -2,dy: -2) },
            arguments: [field]) else { throw GrainError.kernel }
        let wide = try gaussian(quarter, sigma: wideSigma < 0.3 ? 0 : wideSigma, maxRadius: 16)
            .transformed(by: CGAffineTransform(scaleX: 4,y: 4))
        let radius = min(8,Int(ceil(2.5*sigma)))
        var sum=1.0, squares=1.0
        for i in 1...max(1,radius) {
            let w=exp(-0.5*Double(i*i)/(sigma*sigma))
            sum += 2*w; squares += 2*w*w
        }
        let a=squares/(sum*sum), s2=max(8.4*sigma,sqrt(3.92))
        let variance=a*a-2*0.95/(2*Double.pi*(sigma*sigma+s2*s2))+0.95*0.95/(4*Double.pi*s2*s2)
        let normalization=1/sqrt(max(variance/3,1e-8))
        let amplitude=0.405*0.210*Self.resolutionAmplitude(size: size, shortSide: shortSide)
        guard let result = finish.apply(extent: extent, roiCallback: { _, rect in rect }, arguments: [
            softened, source, narrow, wide,
            CIVector(x: normalization,y: settings.strength.clamped(to: 0...5),z: amplitude,w: settings.distribution.clamped(to: 0...1)),
            CIVector(x: weights.x,y: weights.y,z: weights.z), ceiling
        ]) else { throw GrainError.kernel }
        return result
    }

    /// Upstream's phase-averaged Hermite downsampling attenuation.
    private static func resolutionAmplitude(size: Double, shortSide: Double) -> Double {
        let scale=min((2160 / EffectResolution.referenceShortSide) / EffectResolution.scale(shortSide: shortSide),11)
        guard scale>1 else { return 1 }
        let radius=min(8,Int(ceil(2.5*size)))
        let w=(0...8).map { $0<=radius ? exp(-0.5*Double($0*$0)/(size*size)) : 0 }
        var rho=[Double](repeating:0,count:17)
        for m in 0...16 {
            for d in -radius...radius where abs(d+m)<=radius { rho[m] += w[abs(d)]*w[abs(d+m)] }
        }
        let zero=rho[0]
        rho=rho.map { $0/zero }
        var variance=0.0
        for phase in 0..<8 {
            let center=(Double(phase)+0.5)/8
            let origin=floor(center-scale)+1
            let h=(0..<24).map { i -> Double in
                let x=abs((origin+Double(i)-center)/scale)
                return x<1 ? (2*x-3)*x*x+1 : 0
            }
            let total=h.reduce(0,+)
            var v=0.0
            for t in 0..<24 where h[t]>0 {
                for u in 0..<24 where h[u]>0 && abs(t-u)<=2*radius { v += h[t]*h[u]*rho[abs(t-u)] }
            }
            variance += v/(total*total)
        }
        return (variance/8).clamped(to: 0...1)
    }
}
