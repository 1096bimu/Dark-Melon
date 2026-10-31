import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import Dark_Melon

@main struct ImageComparisonChecks {
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
        let inputs = (0..<5).map { ComparisonInput(id: "\($0)", url: url, title: "Image \($0)", recipe: recipe) }
        let session = ImageComparisonSession()
        let start = ProcessInfo.processInfo.systemUptime
        session.start(inputs, film: nil, canvas: CGSize(width: 128,height: 128))
        for _ in 0..<600 {
            if session.panes.count == 4 && session.panes.allSatisfy({ $0.images != nil || $0.error != nil }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(session.count == 5 && session.panes.count == 4)
        precondition(session.panes.allSatisfy { $0.images != nil }, "Overview failed: \(session.panes.map(\.error))")
        precondition(Set(session.panes.compactMap { $0.development?.id }).count == 1, "Matching snapshots decoded separately")
        precondition(session.panes[0].images!.sdr === session.panes[1].images!.sdr, "Matching render was not shared")
        print("Four overviews ready in \((ProcessInfo.processInfo.systemUptime-start)*1000) ms")
        let view = ComparisonDisplay(frame: CGRect(x: 0,y: 0,width: 800,height: 600))
        session.mode = .combine
        view.update(session: session, hdr: false, dimmed: false, mouse: true, reverse: false)
        view.layoutSubtreeIfNeeded()
        let views = view.subviews.compactMap { $0.subviews.first as? HDRImagePreview.ImageDisplay }
        precondition(views.count == 4)
        let origin = views[0].convert(CGPoint.zero, to: view)
        for child in views { precondition(child.convert(CGPoint.zero, to: view) == origin, "Combine seam geometry mismatch") }
        views[0].setNormalizedViewport((3, CGPoint(x: 0.1,y: -0.05)))
        views[0].viewportChanged?()
        for child in views { precondition(abs(child.normalizedViewport.0 - 3) < 0.001) }
        session.mode = .area
        view.update(session: session, hdr: false, dimmed: false, mouse: true, reverse: false)
        let region = PreviewRegion(rect: CGRect(x: 0.3,y: 0.3,width: 0.3,height: 0.3),displayPixels: CGSize(width: 512,height: 256))
        for pane in session.panes { session.requestDetail(pane.id, region: region, hdr: false) }
        for _ in 0..<600 {
            if session.panes.allSatisfy({ $0.detail != nil }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(session.panes.allSatisfy { $0.detail != nil }, "Detail failed")
        precondition(session.panes[0].detail!.image === session.panes[1].detail!.image, "Detail not shared")
        var changed = recipe
        changed.mapping.concentration = 0.55
        let variants = [inputs[0], ComparisonInput(id: "different", url: url, title: "Different snapshot", recipe: changed)]
        session.start(variants, film: nil, canvas: CGSize(width:128,height:128))
        for _ in 0..<600 {
            if session.panes.allSatisfy({ $0.images != nil }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(session.panes[0].recipe!.mapping.concentration == recipe.mapping.concentration)
        precondition(session.panes[1].recipe!.mapping.concentration == 0.55)
        precondition(session.panes[0].development!.id == session.panes[1].development!.id)
        precondition(session.panes[0].images!.sdr !== session.panes[1].images!.sdr)
        let film = FilmSettings(changed.mapping, selection: SettingsPasteSelection(items: [.contrast]))
        session.start(variants, film: film, canvas: CGSize(width:128,height:128))
        for _ in 0..<600 {
            if session.panes.allSatisfy({ $0.images != nil }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(session.panes.allSatisfy { $0.recipe?.mapping.concentration == 0.55 })
        let smallMemoryCache = RAWImageCache(memory: 8 * 1024 * 1024 * 1024)
        precondition(smallMemoryCache.comparisonParallelism(pixels: 60_000_000) == 1)
        precondition(smallMemoryCache.comparisonParallelism(pixels: 1_000_000) == 2)
        session.start(inputs, film: nil, canvas: CGSize(width: 64,height: 64))
        session.stop()
        try await Task.sleep(for: .milliseconds(200))
        precondition(session.panes.isEmpty, "Stale work republished after exit")
        print("Selection limit, source/render sharing, Combine geometry, synchronized zoom, detail and cancellation passed")
    }
}
