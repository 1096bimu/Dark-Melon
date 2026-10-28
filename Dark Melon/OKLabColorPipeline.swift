import CoreImage
import Foundation
import simd

/// One forward and one final inverse conversion for the complete Color + vertex stage.
nonisolated final class OKLabColorPipeline {
    private var tintCache: (SplitToneSettings, ProcessingColorSpace, Double, CIImage)?
    private var fieldCache: ([OKLabVertexAdjustment], ProcessingColorSpace, OKLabVertexWarp.Field)?
    private let kernel = MetalImageKernels.general("combinedOKLab")

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
