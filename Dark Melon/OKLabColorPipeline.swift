import CoreImage
import Foundation
import simd

/// One forward and one final inverse conversion for the complete Color + vertex stage.
nonisolated final class OKLabColorPipeline {
    private var tintCache: (SplitToneSettings, ProcessingColorSpace, Double, CIImage)?
    private var fieldCache: ([OKLabVertexAdjustment], ProcessingColorSpace, OKLabVertexWarp.Field)?
    private let kernel: CIKernel? = {
        let parameters=(0..<6).map { "vec4 v\($0),vec2 h\($0)" }.joined(separator:",")
        let sectors=(0..<6).map { i in
            let j=(i+1)%6
            return """
            if (h>=h\(i).x && h<=h\(i).y) {
                float t=(h-h\(i).x)/(h\(i).y-h\(i).x);
                float w=t*t*(3.0-2.0*t);
                adjustment=mix(v\(i).xyz,v\(j).xyz,w);
                float r0=clamp(c/v\(i).w,0.0,1.0),r1=clamp(c/v\(j).w,0.0,1.0);
                adjustment.y=mix(v\(i).y*r0*r0*(3.0-2.0*r0),v\(j).y*r1*r1*(3.0-2.0*r1),w);
            }
            """
        }.joined(separator:"\n")
        return CIKernel(source:ColorPixelKernel.functions + """
        kernel vec4 combinedOKLab(sampler image,sampler tintTable,
            float ceiling,float domain,float maximumChroma,vec4 chroma,vec4 lightness,
            float hasTint,float hasWarp,
            vec3 to0,vec3 to1,vec3 to2,vec3 from0,vec3 from1,vec3 from2,
            \(parameters)) {
            vec4 pixel=unpremultiply(sample(image,samplerCoord(image)));
            vec3 lab=toOKLab(convertRGB(pixel.rgb,to0,to1,to2));
            float multiplier=chromaMultiplier(length(lab.yz)/maximumChroma,chroma,domain)
                * chromaMultiplier(lab.x,lightness,domain);
            lab.yz *= max(0.0,multiplier);
            if (hasWarp > 0.5) {
                float scale=pow(ceiling,1.0/3.0);
                vec3 q=lab/scale;
                float c=length(q.yz);
                vec3 warped=q;
                if (c>0.0000000001) {
                    float h=atan(q.z,q.y);
                    if (h<h0.x) { h+=6.28318530718; }
                    vec3 adjustment=vec3(1.0,0.0,0.0);
                    \(sectors)
                    warped=vec3(q.x+adjustment.y,c*adjustment.x*cos(h+adjustment.z),c*adjustment.x*sin(h+adjustment.z));
                }
                lab=warped*scale;
            }
            if (hasTint > 0.5) {
                lab.yz += sample(tintTable,vec2(clamp(lab.x/domain,0.0,1.0)*511.0+0.5,0.5)).xy;
            }
            // Gamut handling is deferred until every OKLab operation is complete.
            // Retain lightness, reducing chroma only where the final color cannot fit.
            vec3 rgb=convertRGB(fromOKLab(lab),from0,from1,from2);
            if (min(rgb.r,min(rgb.g,rgb.b)) < -0.00001 || max(rgb.r,max(rgb.g,rgb.b)) > ceiling+0.00001) {
                float low=0.0; float high=1.0;
                for (int i=0;i<14;i++) {
                    float t=(low+high)*0.5;
                    vec3 candidate=convertRGB(fromOKLab(vec3(lab.x,lab.yz*t)),from0,from1,from2);
                    if (min(candidate.r,min(candidate.g,candidate.b))>=0.0 && max(candidate.r,max(candidate.g,candidate.b))<=ceiling) { low=t; } else { high=t; }
                }
                rgb=convertRGB(fromOKLab(vec3(lab.x,lab.yz*low)),from0,from1,from2);
            }
            return premultiply(vec4(rgb,pixel.a));
        }
        """)
    }()

    func apply(_ image:CIImage,color:ColorAdjustments,vertices:[OKLabVertexAdjustment],space:ProcessingColorSpace,ceiling:Double,domainCeiling:Double) throws -> CIImage {
        let hasWarp = !vertices.allSatisfy(\.isIdentity)
        guard !color.isIdentity || hasWarp else { return image }
        if tintCache?.0 != color.splitTone || tintCache?.1 != space || tintCache?.2 != domainCeiling {
            tintCache=(color.splitTone,space,domainCeiling,SplitToneGradient.table(settings:color.splitTone,space:space,ceiling:domainCeiling))
        }
        if fieldCache?.0 != vertices || fieldCache?.1 != space {
            fieldCache=(vertices,space,OKLabVertexWarp.field(controls:vertices,space:space))
        }
        let table=tintCache!.3, field=fieldCache!.2
        let to=ScopeProjection.matrix(.sRGB).inverse * ScopeProjection.matrix(space), from=to.inverse
        func vector(_ v:SIMD3<Double>)->CIVector { CIVector(x:v.x,y:v.y,z:v.z) }
        var args:[Any]=[image,CISampler(image:table,options:[kCISamplerFilterMode:kCISamplerFilterLinear,kCISamplerWrapMode:kCISamplerWrapClamp]),
            ceiling,cbrt(domainCeiling),OKLCHGamut.maxima[space]!,
            CIVector(x:color.saturationStart,y:color.saturationMid,z:color.saturationEnd,w:color.saturationHDR),
            CIVector(x:color.luminanceSaturationStart,y:color.luminanceSaturationMid,z:color.luminanceSaturationEnd,w:color.luminanceSaturationHDR),
            color.splitTone.isIdentity ? 0.0:1.0,hasWarp ? 1.0:0.0]
        for m in [to,from] { for i in 0..<3 { args.append(vector(SIMD3(m[0][i],m[1][i],m[2][i]))) } }
        for i in 0..<6 {
            let v=field.adjustments[i], p=field.centers[i]
            args.append(CIVector(x:v.x,y:v.y,z:v.z,w:hypot(p.y,p.z)))
            args.append(CIVector(x:field.hues[i],y:i==5 ? field.hues[0]+2 * .pi:field.hues[i+1]))
        }
        guard let output=kernel?.apply(extent:image.extent,roiCallback:{index,rect in index==1 ? table.extent:rect},arguments:args) else { throw CocoaError(.coderInvalidValue) }
        return output
    }
}
