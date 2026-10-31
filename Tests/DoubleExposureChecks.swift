import Foundation
import CoreImage
import ImageIO
@testable import Dark_Melon

@main struct DoubleExposureChecks {
    static func main() async throws {
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
        let background = CIImage(color: CIColor(red: 0.8, green: 0.3, blue: 0.1)).cropped(to: CGRect(x: 0,y: 0,width: 40,height: 20))
        let base = CIImage(color: CIColor(red: 0.1, green: 0.8, blue: 0.3)).cropped(to: CGRect(x: 2,y: 1,width: 10,height: 7)).composited(over: background)
        func pixels(_ image: CIImage) -> [Float] {
            let width = Int(image.extent.width), height = Int(image.extent.height)
            var values = [Float](repeating: 0, count: width * height * 4)
            context.render(image, toBitmap: &values, rowBytes: width * 16, bounds: image.extent, format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
            return values
        }
        func sample(_ image: CIImage) -> [Float] {
            var values = [Float](repeating: 0, count: 4)
            context.render(image, toBitmap: &values, rowBytes: 16, bounds: CGRect(x: image.extent.midX,y: image.extent.midY,width: 1,height: 1), format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
            return values
        }
        for a: Int32 in 1...8 { for b: Int32 in 1...8 {
            let combined = try DoubleExposure.combine(base.oriented(forExifOrientation: a), base.oriented(forExifOrientation: b), firstOrientation: a, secondOrientation: b)
            precondition(combined.extent.size == base.oriented(forExifOrientation: a).extent.size)
            let expected = base.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x:2,y:0,z:0,w:0), "inputGVector": CIVector(x:0,y:2,z:0,w:0), "inputBVector": CIVector(x:0,y:0,z:2,w:0)]).oriented(forExifOrientation:a)
            precondition(zip(pixels(combined), pixels(expected)).allSatisfy { abs($0 - $1) < 0.005 }, "Spatial orientation mismatch")
            let value = sample(combined)
            precondition(abs(value[0] - sample(base)[0] * 2) < 0.005 && abs(value[1] - sample(base)[1] * 2) < 0.005 && value[3] == 1)
        }}
        for turn in 0..<4 { for mirror in [false,true] { for secondTurn in [0,2] { for secondMirror in [false,true] {
            let firstGeometry = SourceOrientation(quarterTurns:turn, mirrored:mirror)
            let secondGeometry = SourceOrientation(quarterTurns:secondTurn, mirrored:secondMirror)
            let output = try DoubleExposure.combine(base.oriented(forExifOrientation:8), base.oriented(forExifOrientation:6), firstOrientation:8, secondOrientation:6, firstGeometry:firstGeometry, secondGeometry:secondGeometry)
            let firstPixels = pixels(firstGeometry.apply(to:base.oriented(forExifOrientation:8)))
            let secondPixels = pixels(secondGeometry.apply(to:firstGeometry.apply(to:base.oriented(forExifOrientation:8), includeMirror:false)))
            let actual = pixels(output)
            for index in actual.indices where index % 4 != 3 {
                precondition(abs(actual[index] - firstPixels[index] - secondPixels[index]) < 0.005)
            }
        }}}}
        var geometrySettings = RAWSettings()
        geometrySettings.orientation = SourceOrientation(quarterTurns:1, mirrored:true)
        let geometryCopy = try JSONDecoder().decode(RAWSettings.self, from:JSONEncoder().encode(geometrySettings))
        precondition(geometryCopy.orientation == geometrySettings.orientation)
        let pastedGeometry = SettingsPasteSelection(items:[.sourceOrientation]).applyingRAW(geometrySettings, to:RAWSettings())!
        precondition(pastedGeometry.orientation == geometrySettings.orientation)
        do { _ = try DoubleExposure.combine(base, base.cropped(to: CGRect(x:0,y:0,width:20,height:20)), firstOrientation:1, secondOrientation:1); fatalError("Accepted unequal dimensions") } catch DoubleExposure.Failure.dimensions {}
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var recipe = DevelopmentRecipe(colorSpace: .displayP3, mapping: .fresh(isRAW: true, sourceHeadroom: 1), rawSettings: RAWSettings())
        recipe.mapping.doubleExposure = DoubleExposure(first:"a.ARW",second:"b.ARW",secondRAW:RAWSettings(),secondBalance:nil)
        recipe.mapping.white = 1.5
        recipe.mapping.setAutomaticHDRTarget()
        precondition(recipe.mapping.curve(hdr:true).white == 2)
        recipe.snapshots = [NamedSnapshot(name:"Test", edit: SnapshotEdit(recipe))]
        let url = folder.appendingPathComponent("Test.double.darkmelon.xmp")
        try await RecipeStore.shared.save(recipe, for:url)
        let loaded = try await RecipeStore.shared.load(for:url)!
        precondition(loaded.mapping.doubleExposure == recipe.mapping.doubleExposure)
        precondition(loaded.snapshots[0].edit.mapping.doubleExposure != nil)
        let copied = try CopiedSettings.decode(CopiedSettings.encode(recipe, reference:nil))
        precondition(copied.mapping.doubleExposure == nil && copied.rawSettings == recipe.rawSettings)
        var source = recipe.mapping; source.rawWhiteBalance = try JSONDecoder().decode(RAWWhiteBalance.self, from: Data(#"{"temperature":5000,"tint":5}"#.utf8))
        var raw = RAWSettings(); raw.values[.exposure] = -1
        recipe.applySecondRAW(from:source, raw:raw, selection:SettingsPasteSelection(items:[.exposure,.rawWhiteBalance]))
        precondition(recipe.mapping.doubleExposure!.secondRAW.values[.exposure] == -1)
        precondition(recipe.mapping.doubleExposure!.secondBalance == source.rawWhiteBalance)
        if CommandLine.arguments.count > 1 {
            let rawURL = URL(fileURLWithPath: CommandLine.arguments[1])
            for name in ["a.ARW", "b.ARW"] { try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent(name), withDestinationURL: rawURL) }
            let singleWorker = RAWDeveloper(colorSpace: .displayP3)
            var resolved = try await singleWorker.resolveExportRecipe(rawURL, recipe: recipe.transferable, isRAW: true, maximizeRange: false)
            resolved.mapping.doubleExposure = DoubleExposure(first:"a.ARW",second:"b.ARW",secondRAW:resolved.rawSettings!,secondBalance:resolved.mapping.rawWhiteBalance)
            resolved.mapping.white = 0.5; resolved.mapping.setAutomaticHDRTarget()
            try await RecipeStore.shared.save(resolved, for:url)
            let worker = RAWDeveloper(colorSpace:.displayP3, rawSettings:resolved.rawSettings, rawWhiteBalance:resolved.mapping.rawWhiteBalance, doubleExposure:resolved.mapping.doubleExposure)
            let single = try await singleWorker.develop(rawURL, previewCanvas: CGSize(width:512,height:512), progressive:true)
            let pair = try await worker.develop(url, previewCanvas: CGSize(width:512,height:512), progressive:true)
            precondition(pair.width == single.width && pair.height == single.height, "Dimensions: \(pair.width)x\(pair.height) vs \(single.width)x\(single.height)")
            let a = sample(CIImage(cgImage: single.preview)), b = sample(CIImage(cgImage: pair.preview))
            precondition(abs(a[0]*2-b[0]) < 0.01, "RAW sum mismatch: \(a) / \(b)")
            var changed = resolved.mapping.doubleExposure!
            changed.secondRAW.values[.exposure] = (changed.secondRAW.values[.exposure] ?? 0) - 1
            await worker.updateRAWSettings(resolved.rawSettings, whiteBalance: resolved.mapping.rawWhiteBalance, doubleExposure: changed)
            let adjusted = try await worker.develop(url, previewCanvas: CGSize(width:512,height:512), progressive:true)
            let c = sample(CIImage(cgImage:adjusted.preview))
            precondition(c[0] < b[0] && c[0] >= a[0] - 0.01, "Second source adjustment failed")
            await worker.updateRAWSettings(resolved.rawSettings, whiteBalance: resolved.mapping.rawWhiteBalance, doubleExposure: resolved.mapping.doubleExposure)
            for index in 0..<2 {
                var samples: [[Float]] = []
                for temperature: Float in [5500, 3200] {
                    var pairSettings = resolved.mapping.doubleExposure!
                    var firstBalance = resolved.mapping.rawWhiteBalance
                    if index == 0 { firstBalance = RAWWhiteBalance(temperature: temperature, tint: 0) }
                    else { pairSettings.secondBalance = RAWWhiteBalance(temperature: temperature, tint: 0) }
                    await worker.updateRAWSettings(resolved.rawSettings, whiteBalance: firstBalance, doubleExposure: pairSettings)
                    let updated = try await worker.develop(url, previewCanvas: CGSize(width:512,height:512), progressive:true)
                    samples.append(sample(CIImage(cgImage: updated.preview)))
                }
                precondition(zip(samples[0], samples[1]).contains { abs($0 - $1) > 0.00001 }, "D/T did not change source \(index+1)")
            }
            await worker.updateRAWSettings(resolved.rawSettings, whiteBalance: resolved.mapping.rawWhiteBalance, doubleExposure: resolved.mapping.doubleExposure)
            let root = try await worker.develop(url, previewCanvas: CGSize(width:512,height:512))
            precondition(root.fullResolutionReady)
            let dust = DustSpot(center: CGPoint(x:0.5,y:0.5), radius:0.1, feather:0.05, attenuation:0.2)
            let correctedRoot = try await worker.develop(url, previewCanvas: CGSize(width:512,height:512), dustSpots:[dust])
            let uncorrectedPixel = sample(root.linearSource), correctedPixel = sample(correctedRoot.linearSource)
            precondition(abs(correctedPixel[0]-uncorrectedPixel[0]/0.8)<0.01,"Composite dust correction")
            let stamp = RAWImageCache.FileStamp(rawURL)!
            precondition(RAWImageCache.shared.lookup(stamp,space:.displayP3,settings:resolved.rawSettings,balance:resolved.mapping.rawWhiteBalance) == nil,
                         "Composition retained a component in the shared source cache")
            let inspectionWorker = RAWDeveloper(colorSpace:.displayP3,rawSettings:resolved.rawSettings,rawWhiteBalance:resolved.mapping.rawWhiteBalance,interactive:true)
            let inspection = try await inspectionWorker.develop(rawURL,previewCanvas:CGSize(width:512,height:512),progressive:true)
            _ = try await inspectionWorker.prepareFullResolution(inspection)
            precondition(RAWImageCache.shared.lookup(stamp,space:.displayP3,settings:resolved.rawSettings,balance:resolved.mapping.rawWhiteBalance) != nil,
                         "Independent RAW inspection did not populate the normal cache")
            print("Composite source baking/dust and independent inspection cache passed")
            var options = HEIFSettings(); options.format = .jpeg; options.scale = 0.1; options.jpegHDR = false
            let jpeg = try await worker.exportHEIF(url, mapping:resolved.mapping, settings:options)
            precondition(CGImageSourceCreateWithData(jpeg as CFData,nil) != nil)
            try await RecipeStore.shared.delete(for:url)
            let reset = try await RecipeStore.shared.load(for:url)
            precondition(reset == nil)
            print("Real RAW pair progressive decode, addition, JPEG export and document deletion passed")
        }
        print("64 orientation pairs, unclipped addition, extent rejection, persistence, snapshots, ordinary clipboard, RAW paste, and deletion passed")
    }
}
