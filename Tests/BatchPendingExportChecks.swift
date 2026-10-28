import Foundation
import CoreImage
@testable import Dark_Melon

@main struct BatchPendingExportChecks {
    @MainActor static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = (0..<3).map { folder.appendingPathComponent("image\($0).png") }
        let context = CIContext()
        let image = CIImage(color: CIColor(red:0.2,green:0.1,blue:0.3)).cropped(to:CGRect(x:0,y:0,width:16,height:16))
        for file in files { try context.writePNGRepresentation(of:image,to:file,format:.RGBA8,colorSpace:ProcessingColorSpace.sRGB.encoded) }
        var saved = DevelopmentRecipe(colorSpace:.sRGB,mapping:ToneMapping())
        saved.mapping.concentration = 0.1
        try await RecipeStore.shared.save(saved,for:files[0])
        try await RecipeStore.shared.save(saved,for:files[2])
        var pending = saved
        pending.mapping.concentration = 0.7
        pending.mapping.white = 0.35
        pending.mapping.clarity = 0.6
        pending.mapping.rawWhiteBalance = RAWWhiteBalance(RAWWhitePoint(chromaticity: CGPoint(x:0.33,y:0.33),temperature:5000,tint:4)!)
        var raw = RAWSettings()
        raw.values[.exposure] = -1
        pending.rawSettings = raw
        let overrides = [files[0]:pending,files[1]:pending]
        let unlocked = try await ExportPlan.prepare(files:files,film:nil,maximizeRAWRange:true,recipeOverrides:overrides) { _,_ in }
        precondition(unlocked.failures.isEmpty)
        precondition(unlocked.items[0].recipe == pending && unlocked.items[1].recipe == pending)
        precondition(unlocked.items[2].recipe.mapping.concentration == saved.mapping.concentration)
        var lockMapping = ToneMapping()
        lockMapping.concentration = 0.4
        lockMapping.rawWhiteBalance = RAWWhiteBalance(RAWWhitePoint(chromaticity: CGPoint(x:0.33,y:0.33),temperature:6500,tint:8)!)
        var lockRAW = RAWSettings(); lockRAW.values[.exposure] = -2
        let film = FilmSettings(lockMapping,rawSettings:lockRAW,selection:SettingsPasteSelection(items:[.contrast,.rawWhiteBalance,.exposure]))
        let locked = try await ExportPlan.prepare(files:files,film:film,maximizeRAWRange:true,recipeOverrides:overrides) { _,_ in }
        precondition(locked.failures.isEmpty)
        precondition(locked.items[0].recipe == film.applying(to:pending))
        precondition(locked.items[1].recipe == film.applying(to:pending))
        precondition(locked.items[0].recipe.mapping.white == pending.mapping.white)
        precondition(locked.items[0].recipe.mapping.clarity == pending.mapping.clarity)
        precondition(locked.items[0].recipe.rawSettings?.values[.exposure] == -2)
        // Subsequent changes do not modify the prepared value snapshot.
        pending.mapping.white = 0.9
        precondition(locked.items[0].recipe.mapping.white == 0.35)
        print("PASS: pending overrides saved/default recipes, Film Lock wins only selected fields including RAW, prepared recipes remain frozen")
    }
}
