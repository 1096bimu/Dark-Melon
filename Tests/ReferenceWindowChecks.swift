import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import Dark_Melon

@main struct ReferenceWindowChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("source.png")
        let image = CIImage(color: CIColor(red: 0.3, green: 0.15, blue: 0.1)).cropped(to: CGRect(x: 0,y: 0,width: 512,height: 256))
        let context = CIContext()
        let bitmap = context.createCGImage(image, from: image.extent)!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, bitmap, nil)
        precondition(CGImageDestinationFinalize(destination))
        let recipe = DevelopmentRecipe(colorSpace: .sRGB, mapping: .fresh(isRAW: false, sourceHeadroom: 1))
        let loaded = try await BrowserFileDevelopment.load(url, override: recipe, bins: 64)
        let frozen = try await loaded.worker.referenceImages(loaded.development, mapping: loaded.recipe.mapping)
        let bytes = frozen.sdr.dataProvider!.data! as Data
        try FileManager.default.removeItem(at: url)
        precondition(frozen.sdr.width == 512 && frozen.sdr.height == 256)
        precondition((frozen.sdr.dataProvider!.data! as Data) == bytes)
        let link = ReferenceViewportLink()
        let main = HDRImagePreview.ImageDisplay(viewport: PreviewViewport())
        let reference = HDRImagePreview.ImageDisplay(viewport: PreviewViewport())
        for view in [main, reference] {
            view.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
            view.display(frozen.sdr, sdrImage: frozen.sdr, surface: nil, sdrSurface: nil,
                sourceSize: CGSize(width: 512, height: 256), detail: nil,
                hdr: false, sourceID: UUID(), screenSaverActive: false)
        }
        link.main = main
        let id = UUID()
        main.setNormalizedViewport((3, CGPoint(x: 0.1, y: -0.1)))
        link.set(reference, id: id, synchronized: true)
        precondition(reference.normalizedViewport.0 == 3)
        reference.setNormalizedViewport((2, .zero))
        link.changed(reference)
        precondition(main.normalizedViewport.0 == 2)
        link.set(reference, id: id, synchronized: false)
        main.setNormalizedViewport((4, .zero))
        link.changed(main)
        precondition(reference.normalizedViewport.0 == 2)
        print("Frozen full-resolution pixels survive source deletion; bidirectional viewport sync and unlink passed")
    }
}
