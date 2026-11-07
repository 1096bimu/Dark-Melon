import Foundation
import CoreImage
@testable import Dark_Melon

@main struct AnalogueFogChecks {
    static func main() async throws {
        let base=FilmGrain.defaultFog, target = -expm1(-FilmGrain.defaultFog)
        var identity=ToneMapping.fresh(isRAW:false,sourceHeadroom:1);identity.grain.output = .filmDensity
        precondition(identity.analogueFog==base)
        var dark=identity;dark.tonePosition=0.8;dark.concentration=0.6
        precondition(dark.analogueFog==base)
        var bright=ToneMapping();bright.grain.output = .filmDensity
        bright.tonePosition=0.01;bright.concentration=0.3
        let fog=bright.analogueFog
        precondition(fog>0 && fog<base/2)
        let oldOutput=bright.curve(hdr:false).value(at:target)
        let output=bright.curve(hdr:false).value(at:-expm1(-fog))
        precondition(abs(output-target)<1e-10 && oldOutput>target*5)
        for white in [ToneMapping.minimumRange,0.001,0.01,0.5,1] {
            for position in [0.0,0.001,0.02,0.5,1] {
                for contrast in [-1.0,0,0.3,1] {
                    var mapping=bright;mapping.white=white;mapping.tonePosition=white*position;mapping.concentration=contrast
                    mapping.contrastDistribution=ToneContrastDistribution(black:0.3,shadowWidth:0.1,highlightWidth:0.8,white:0.4)
                    let f=mapping.analogueFog
                    precondition(f.isFinite && (0...base).contains(f))
                    let curve=mapping.curve(hdr:false)
                    let black=curve.value(at:-expm1(-f))
                    precondition(black<=target+1e-9)
                    if f<base { precondition(abs(black-target)<1e-8) }
                }
            }
        }
        var hdr=bright;hdr.hdrGain=5;hdr.hdrRolloff=0.7
        precondition(hdr.analogueFog==fog,"SDR/HDR share one fog density")
        var digital=bright;digital.grain.output = .additive
        precondition(digital.analogueFog==base)
        let space=ProcessingColorSpace.sRGB
        let context=CIContext(options:[.workingColorSpace:space.linear,.workingFormat:CIFormat.RGBAf])
        let extent=CGRect(x:0,y:0,width:256,height:256)
        func source(_ level:Double) -> CIImage {
            CIImage(color:CIColor(red:level,green:level,blue:level,colorSpace:space.linear)!).cropped(to:extent)
        }
        func red(_ image:CIImage) -> [Double] {
            var pixels=[Float](repeating:0,count:256*256*4)
            context.render(image,toBitmap:&pixels,rowBytes:256*16,bounds:extent,format:.RGBAf,colorSpace:space.linear)
            return stride(from:0,to:pixels.count,by:4).map { Double(pixels[$0]) }
        }
        let film=FilmResponse(),grain=try FilmGrain()
        let black=source(0)
        let meanImage=try film.apply(to:black,mapping:bright)
        precondition(red(meanImage).allSatisfy { abs($0-(-expm1(-fog)))<2e-7 })
        // Reconstruct the normalized Analogue texture from its density output and
        // check the density/noise formula independently with adaptive fog.
        var settings=FilmGrainSettings();settings.output = .filmDensity;settings.strength=1;settings.colorScale=0
        let neutral=source(0.18)
        let reference=red(try grain.apply(to:neutral,settings:settings))
        let softened=red(neutral.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:settings.size/2]).cropped(to:extent))
        let unit=zip(reference,softened).map { value, input in
            let d=FilmGrain.defaultFog+4*input/(input+4)
            return (-log1p(-value)-d)/(8*0.0008505*sqrt(d))
        }
        bright.grain=settings;bright.grain.output = .filmDensity
        let noisy=red(try film.apply(to:black,mapping:bright))
        for (value,n) in zip(noisy,unit) {
            let expected = -expm1(-max(0,fog+8*0.0008505*sqrt(fog)*n))
            precondition(abs(value-expected)<2e-6)
        }
        precondition(noisy.max()!>noisy.min()! && noisy.contains(0),"Adaptive fog retains texture and reaches black")
        // Output-matrix gain must not reintroduce a large neutral pedestal.
        var mixed=bright;mixed.grain.strength=0;mixed.channelContrast=[1,-1,0]
        mixed.dyePurity=[0.2,0.4,0.6];mixed.dyeMixers.b=[2,0,0,0,1,0,0,0,0.5]
        let mixedBlack=red(try film.apply(to:black,mapping:mixed))
        precondition(mixedBlack.allSatisfy { mixed.curve(hdr:false).value(at:$0)<=target+1e-6 })
        // Very small derived densities survive float conversion and exp subtraction.
        var tiny=bright;tiny.white=ToneMapping.minimumRange;tiny.tonePosition=0;tiny.concentration=1;tiny.grain.strength=0
        let tinyFog=tiny.analogueFog
        let tinyPixels=red(try film.apply(to:black,mapping:tiny))
        precondition(tinyFog>0 && tinyPixels.allSatisfy { $0>0 && abs($0-(-expm1(-tinyFog)))<tinyFog*1e-5 })
        let worker=RAWDeveloper(colorSpace:space)
        bright.grain.strength=0
        let rendered=red(try await worker.mappedImage(black,mapping:bright,hdr:false))
        precondition(rendered.allSatisfy { abs($0-target)<1e-6 })
        let lut=try await worker.sampleSDRLUT(mapping:bright,dimension:17)
        let code=Float(space.sdrCode(forLinear:target)/255)
        precondition(abs(lut.values[0].x-code)<0.001)
        var export=HEIFSettings();export.format = .tiff;export.tiff16Bit=true;export.tiffHDR=false
        let encoded=try await worker.exportImage(black,mapping:bright,settings:export)
        let exported=red(CIImage(data:encoded)!)
        precondition(exported.allSatisfy { abs($0-target)<0.00005 })
        let recipe=DevelopmentRecipe(colorSpace:space,mapping:bright)
        let restored=try DevelopmentRecipe.decode(recipe.encoded())
        precondition(restored.mapping.analogueFog==fog)
        print("PASS: fog cap across tone/contrast/white/distribution, unchanged identity/darkening, shared HDR density, original texture, noise statistics, matrix gain, tiny-fog precision, preview/LUT/export and derived persistence")
        print("Tone .01, Contrast 30%, white .5: fog \(fog), base black \(space.sdrCode(forLinear:output)) / 255 (previously \(space.sdrCode(forLinear:oldOutput)))")
    }
}
