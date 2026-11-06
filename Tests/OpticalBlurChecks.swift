import Foundation
import CoreImage
@testable import Dark_Melon

@main struct OpticalBlurChecks {
    static func main() async throws {
        let space = ProcessingColorSpace.sRGB
        let context = CIContext(options: [.workingColorSpace: space.linear, .workingFormat: CIFormat.RGBAf])
        let extent = CGRect(x: 0, y: 0, width: 512, height: 384)
        func constant(_ value: Double, extent: CGRect) -> CIImage {
            CIImage(color: CIColor(red: value, green: value, blue: value, colorSpace: space.linear)!).cropped(to: extent)
        }
        func pixels(_ image: CIImage) -> [Float] {
            let bounds = image.extent.integral
            var values = [Float](repeating: 0, count: Int(bounds.width*bounds.height)*4)
            context.render(image, toBitmap: &values, rowBytes: Int(bounds.width)*16, bounds: bounds, format: .RGBAf, colorSpace: space.linear)
            return values
        }
        let source = constant(0.45, extent: extent)
        let low = OpticalBlur.source(source)
        precondition(low.extent.width == extent.width/4 && low.extent.height == extent.height/4)
        precondition(low.extent.width*low.extent.height == extent.width*extent.height/16)
        for radius in [4.0, 40, 120] {
            let restored = OpticalBlur.expanded(OpticalBlur.gaussian(low, radius: radius), extent: extent)
            precondition(restored.extent == extent)
            let values = pixels(restored)
            let error = stride(from: 0, to: values.count, by: 4).map { abs(values[$0]-0.45) }.max()!
            precondition(error < 0.001,
                "Shared blur must preserve scene-linear energy and edge extension")
        }
        let shifted = CGRect(x: 7, y: -11, width: 513, height: 385)
        let shiftedLow = OpticalBlur.source(constant(0.45, extent: shifted))
        precondition(OpticalBlur.expanded(shiftedLow, extent: shifted).extent == shifted)
        // Constant fields remove resampling approximation from the order check.
        var mapping = ToneMapping.fresh(isRAW: false, sourceHeadroom: 1)
        mapping.hdrGain = 1
        mapping.hdf = 0.25; mapping.hdfRadius = 70
        mapping.badHDR.strength = 1; mapping.badHDR.radius = 0.8
        mapping.halation.inputCurve = 0.8; mapping.halation.radius = 1; mapping.halation.transmission = 0.3
        let hdf = constant(0.45*(1+mapping.hdf), extent: extent)
        let bad = BadHDR(), halo = Halation()
        let badFirst = try bad.apply(to: hdf, blurred: source, settings: mapping.badHDR, whitePoint: mapping.white, weights: space.luminance)
        let expectedInput = try halo.apply(to: badFirst, source: source, settings: mapping.halation,
            hdrBrightness: mapping.hdrMax, ceiling: 0)
        let worker = RAWDeveloper(colorSpace: space)
        let expected = pixels(try await worker.applyTone(expectedInput, curves: mapping.channelCurves(hdr: true)))
        let actual = pixels(try await worker.mappedImage(source, mapping: mapping, hdr: true))
        precondition(zip(actual, expected).allSatisfy { abs($0-$1) < 0.001 }, "Full-size composites must use independent blur sources")
        let serialBad = try bad.apply(to: hdf, settings: mapping.badHDR, whitePoint: mapping.white, weights: space.luminance)
        let serialHalo = try halo.apply(to: serialBad, source: serialBad, settings: mapping.halation,
            hdrBrightness: mapping.hdrMax, ceiling: 0)
        let serial = pixels(try await worker.applyTone(serialHalo, curves: mapping.channelCurves(hdr: true)))
        precondition(zip(actual, serial).contains { abs($0-$1) > 1e-4 }, "Test must distinguish the former dependent blur chain")
        // A nonuniform vignette must affect the shared masks and the full image.
        mapping.vignette.amount = 2
        let vignetted = try Vignette().apply(to: source, settings: mapping.vignette, transform: nil)
        let vignettedLow = OpticalBlur.source(vignetted)
        let spatialScale = EffectResolution.scale(shortSide: extent.height)
        let hdfBlur = OpticalBlur.expanded(OpticalBlur.gaussian(vignettedLow, radius: mapping.hdfRadius*spatialScale), extent: extent)
        let hdfKernel = MetalImageKernels.color("hdfAdd")!
        let vignettedHDF = hdfKernel.apply(extent: extent, arguments: [vignetted, hdfBlur, mapping.hdf])!
        let mask = OpticalBlur.expanded(OpticalBlur.gaussian(vignettedLow, radius: 50*mapping.badHDR.radius*spatialScale), extent: extent)
        let vignettedBad = try bad.apply(to: vignettedHDF, blurred: mask, settings: mapping.badHDR,
            whitePoint: mapping.white, weights: space.luminance)
        let vignettedHalo = try halo.apply(to: vignettedBad, source: vignettedLow, settings: mapping.halation,
            hdrBrightness: mapping.hdrMax, ceiling: 0, sourceScale: OpticalBlur.scale)
        let vignettedExpected = pixels(try await worker.applyTone(vignettedHalo, curves: mapping.channelCurves(hdr: true)))
        let vignettedActual = pixels(try await worker.mappedImage(source, mapping: mapping, hdr: true))
        precondition(zip(vignettedActual, vignettedExpected).allSatisfy { abs($0-$1) < 1e-5 })
        precondition(zip(vignettedActual, actual).contains { abs($0-$1) > 0.01 })
        mapping.vignette.amount = 0
        mapping.hdf = 0; mapping.badHDR.strength = 0; mapping.hdrGain = 0
        let bypass = pixels(try await worker.mappedImage(source, mapping: mapping, hdr: false))
        let noHalation = pixels(try await worker.applyTone(source, curves: mapping.channelCurves(hdr: false)))
        precondition(zip(bypass, noHalation).allSatisfy { abs($0-$1) < 1e-6 }, "HDR coupling and disabled-effects bypass must remain intact")
        // Grain Size is measured once in source pixels, regardless of image dimensions.
        let grain = try FilmGrain()
        var grainSettings = FilmGrainSettings(); grainSettings.strength = 1; grainSettings.size = 2; grainSettings.colorScale = 0
        let small = try grain.apply(to: constant(0.18, extent: extent), settings: grainSettings)
        let largeExtent = CGRect(x: 0, y: 0, width: 4000, height: 8000)
        let large = try grain.apply(to: constant(0.18, extent: largeExtent), settings: grainSettings).cropped(to: extent)
        precondition(zip(pixels(small), pixels(large)).allSatisfy { abs($0-$1) < 1e-6 }, "Fixed Size must not receive another source-dimension multiplier")
        let preview = try grain.apply(to: constant(0.18, extent: extent), settings: grainSettings, renderScale: 0.5)
        grainSettings.size = 1
        let native = try grain.apply(to: constant(0.18, extent: extent), settings: grainSettings)
        precondition(pixels(preview) == pixels(native), "Preview scale is independent of the source-size default")
        print("PASS: shared quarter-size blur, energy/bounds, vignette before split, independent HDF/BadHDR/halation branches, HDR coupling/bypass, source-pixel grain size and preview scale")
    }
}
