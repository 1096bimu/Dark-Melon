import CoreImage
import Foundation
import simd

/// One forward and one final inverse conversion for the complete Color + vertex stage.
nonisolated final class OKLabColorPipeline {
    private var tintCache: (SplitToneSettings, ProcessingColorSpace, Double, CIImage)?
    private var fieldCache: ([OKLabVertexAdjustment], ProcessingColorSpace, OKLabVertexWarp.Field)?
    private let kernel: CIKernel? = {
        let parameters=(0..<OKLabVertexWarp.count).map { "vec4 v\($0),vec2 h\($0),vec4 b\($0),float l\($0)" }.joined(separator:",")
        let sectors=(0..<OKLabVertexWarp.count).map { i in
            let j=(i+1)%OKLabVertexWarp.count
            return """
            if (h>=h\(i).x && h<=h\(i).y) {
                float t=(h-h\(i).x)/(h\(i).y-h\(i).x);
                float w=t*t*(3.0-2.0*t);
                adjustment=mix(v\(i).xyz,v\(j).xyz,w);
                adjustment.z += mix(sliceBend(q.x,c,b\(i),l\(i)),sliceBend(q.x,c,b\(j),l\(j)),w);
                float r0=clamp(c/v\(i).w,0.0,1.0),r1=clamp(c/v\(j).w,0.0,1.0);
                adjustment.y=mix(v\(i).y*r0*r0*(3.0-2.0*r0),v\(j).y*r1*r1*(3.0-2.0*r1),w);
            }
            """
        }.joined(separator:"\n")
        return CIKernel(source:ColorPixelKernel.functions + """
        float sliceBend(float L,float C,vec4 bend,float apex) {
            float endpoint=L<apex ? bend.x:bend.y;
            float t=clamp(abs(L-apex)/max(0.000001,abs(endpoint-apex)),0.0,1.0);
            float c=clamp(C/0.1,0.0,1.0);
            return (L<apex ? bend.z:bend.w)*t*t*(3.0-2.0*t)*c*c*(3.0-2.0*c);
        }
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
            // Fit along a straight line toward neutral in linear working RGB.
            // The RGB cube is convex, unlike fixed-L OKLab chroma slices near
            // deep blue: this intersection is unique and continuous, with no
            // branch-search jumps. In-gamut colors remain unchanged. Out-of-gamut
            // colors may change perceptual lightness/hue slightly while fitting.
            vec3 rgb=convertRGB(fromOKLab(lab),from0,from1,from2);
            float gray=clamp(lab.x*lab.x*lab.x,0.0,ceiling);
            vec3 delta=rgb-vec3(gray);
            float fit=1.0;
            float lowest=min(rgb.r,min(rgb.g,rgb.b));
            float highest=max(rgb.r,max(rgb.g,rgb.b));
            if (lowest<0.0) { fit=min(fit,gray/(gray-lowest)); }
            if (highest>ceiling) { fit=min(fit,(ceiling-gray)/(highest-gray)); }
            rgb=clamp(vec3(gray)+delta*fit,0.0,ceiling);
            return premultiply(vec4(rgb,pixel.a));
        }
        """)
    }()

    func apply(_ image:CIImage,color:ColorAdjustments,vertices:[OKLabVertexAdjustment],space:ProcessingColorSpace,ceiling:Double,domainCeiling:Double) throws -> CIImage {
        let effectiveVertices = color.monochrome ? vertices.map { vertex in
            var result = vertex
            result.chroma = 0
            result.rotation = 0
            result.hueOffset = 0
            result.darkerHue = 0
            result.lighterHue = 0
            return result
        } : vertices
        let hasWarp = !effectiveVertices.allSatisfy(\.isIdentity)
        guard !color.isIdentity || hasWarp else { return image }
        if tintCache?.0 != color.splitTone || tintCache?.1 != space || tintCache?.2 != domainCeiling {
            tintCache=(color.splitTone,space,domainCeiling,SplitToneGradient.table(settings:color.splitTone,space:space,ceiling:domainCeiling))
        }
        if fieldCache?.0 != effectiveVertices || fieldCache?.1 != space {
            fieldCache=(effectiveVertices,space,OKLabVertexWarp.field(controls:effectiveVertices,space:space))
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
        for i in 0..<OKLabVertexWarp.count {
            let v=field.adjustments[i], p=field.centers[i]
            args.append(CIVector(x:v.x,y:v.y,z:v.z,w:hypot(p.y,p.z)))
            args.append(CIVector(x:field.hues[i],y:i==OKLabVertexWarp.count-1 ? field.hues[0]+2 * .pi:field.hues[i+1]))
            let slice=field.slices[i],bend=field.bends[i]
            args.append(CIVector(x:slice.lower,y:slice.upper,z:bend.x,w:bend.y))
            args.append(slice.apex.x)
        }
        guard let output=kernel?.apply(extent:image.extent,roiCallback:{index,rect in index==1 ? table.extent:rect},arguments:args) else { throw CocoaError(.coderInvalidValue) }
        return output
    }
}
