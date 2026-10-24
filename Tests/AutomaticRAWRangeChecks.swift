import CoreImage
import Foundation
@testable import Dark_Melon

@main struct AutomaticRAWRangeChecks {
    @MainActor static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let raw = folder.appendingPathComponent("test.ARW")
        try FileManager.default.createSymbolicLink(at: raw, withDestinationURL: URL(fileURLWithPath:CommandLine.arguments[1]))
        let key = RAWSettings.maximizeRangePreferenceKey
        let prior = UserDefaults.standard.object(forKey:key)
        defer {
            if let prior { UserDefaults.standard.set(prior,forKey:key) }
            else { UserDefaults.standard.removeObject(forKey:key) }
        }
        let worker = RAWDeveloper()
        let disabled = try await worker.initialRAWSettings(raw,maximizeRange:false)
        assert(disabled == nil)
        let png = folder.appendingPathComponent("test.png")
        let context = CIContext()
        try context.writePNGRepresentation(of: CIImage(color:.gray).cropped(to:CGRect(x:0,y:0,width:16,height:16)),
                                            to:png,format:.RGBA8,colorSpace:ProcessingColorSpace.sRGB.encoded)
        let nonRAW = try await worker.initialRAWSettings(png,maximizeRange:true)
        assert(nonRAW == nil)
        UserDefaults.standard.set(true,forKey:key)
        let fresh = try await BrowserFileDevelopment.load(raw,bins:128)
        assert(fresh.savedRecipe == nil)
        assert(fresh.recipe.rawSettings?.values[.shadowBias] == 0)
        assert(fresh.recipe.rawSettings?.values[.exposure] != 0)
        var edit = fresh.recipe
        edit.rawSettings!.values[.exposure] = 1
        edit.rawSettings!.values[.shadowBias] = 2
        let pending = try await BrowserFileDevelopment.load(raw,override:edit,bins:128)
        assert(pending.recipe.rawSettings?.values[.exposure] == 1 && pending.recipe.rawSettings?.values[.shadowBias] == 2)
        try await RecipeStore.shared.save(edit,for:raw)
        let saved = try await BrowserFileDevelopment.load(raw,bins:128)
        assert(saved.recipe.rawSettings?.values[.exposure] == 1 && saved.recipe.rawSettings?.values[.shadowBias] == 2)
        print("Automatic RAW range: preference off and non-RAW bypass, fresh RAW fitted settings retained in recipe, pending and saved edits preserved.")
    }
}
