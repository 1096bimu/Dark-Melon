import Foundation
import CoreImage
import AppKit
@testable import Dark_Melon

@main struct OverviewDisplayChecks {
    @MainActor static func main() async throws {
        let hd = PreviewResolution.displayCanvas(points: CGSize(width: 1920, height: 1080), scale: 1)!
        let retina = PreviewResolution.displayCanvas(points: CGSize(width: 1920, height: 1080), scale: 2)!
        precondition(hd == CGSize(width: 1920, height: 1080))
        precondition(retina == CGSize(width: 3840, height: 2160))
        precondition(PreviewResolution.displayCanvas(points: .zero, scale: 2) == nil)
        let sourceSize = CGSize(width: 4096, height: 3072)
        precondition(PreviewResolution.overviewScale(source: sourceSize, canvas: retina) == 2160.0/3072)
        precondition(PreviewResolution.overviewScale(source: CGSize(width: 400, height: 300), canvas: retina) == 1)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("screen-test.png")
        defer {
            RAWImageCache.shared.discardPixels(for: file)
            try? FileManager.default.removeItem(at: folder)
        }
        let space = ProcessingColorSpace.sRGB
        let context = CIContext(options: [.workingColorSpace: space.linear])
        let source = CIFilter(name: "CICheckerboardGenerator", parameters: [
            "inputWidth": 4, "inputSharpness": 1,
            "inputColor0": CIColor(red: 0.02, green: 0.04, blue: 0.06),
            "inputColor1": CIColor(red: 0.8, green: 0.7, blue: 0.6)
        ])!.outputImage!.cropped(to: CGRect(origin: .zero, size: sourceSize))
        try context.writePNGRepresentation(of: source, to: file, format: .RGBA8, colorSpace: space.encoded)
        let worker = RAWDeveloper(colorSpace: space, interactive: true)
        let small = try await worker.develop(file, previewCanvas: hd, progressive: true)
        precondition(small.preview.width == 1440 && small.preview.height == 1080 && !small.fullResolutionReady)
        let repeated = try await worker.develop(file, previewCanvas: hd, progressive: true)
        precondition(repeated.preview === small.preview)
        // Move to a Retina display before the full-resolution refinement has finished.
        let pending = try await worker.overview(small, canvas: retina)
        precondition(pending.width == small.preview.width && pending.height == small.preview.height,
            "Pending overview must not enlarge an old proxy")
        let moved = try await worker.develop(file, previewCanvas: retina, progressive: true)
        let large = try await worker.overview(moved, canvas: retina)
        precondition(large.width == 2880 && large.height == 2160)
        let reference = try await RAWDeveloper(colorSpace: space).develop(file, previewCanvas: retina)
        func pixels(_ image: CGImage) -> [Float] {
            var values = [Float](repeating: 0, count: image.width * image.height * 4)
            context.render(CIImage(cgImage: image), toBitmap: &values, rowBytes: image.width * 16,
                bounds: CGRect(x: 0, y: 0, width: image.width, height: image.height), format: .RGBAf, colorSpace: space.linear)
            return values
        }
        let error = zip(pixels(large), pixels(reference.preview)).map { abs($0 - $1) }.max()!
        precondition(error < 0.002, "Larger overview enlarged the old proxy instead of generating new pixels: \(error)")
        let repeatedLarge = try await worker.overview(moved, canvas: retina)
        precondition(repeatedLarge === large)
        let down = try await worker.develop(file, previewCanvas: CGSize(width: 800, height: 600), progressive: true)
        precondition(down.preview.width == 800 && down.preview.height == 600 && !down.fullResolutionReady)
        precondition(down.linearSource.extent.size == sourceSize)
        let full = try await worker.prepareFullResolution(down)
        let resizedFull = try await worker.develop(file, previewCanvas: retina, progressive: true)
        precondition(resizedFull.fullResolutionReady && resizedFull.linearSource === full.linearSource)
        precondition(resizedFull.id == full.id && resizedFull.preview.width == 2880 && resizedFull.preview.height == 2160)

        // Exercise the native window attachment and screen-change notification path.
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let probe = OverviewDisplayProbe.Probe()
        var reported: CGSize?
        probe.report = { reported = $0 }
        window.contentView = probe
        func waitForReport() async throws {
            for _ in 0..<100 {
                if reported != nil { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            preconditionFailure("No display resolution reported")
        }
        try await waitForReport()
        let current = window.screen!
        precondition(reported == PreviewResolution.displayCanvas(points: current.frame.size, scale: current.backingScaleFactor))
        if let other = NSScreen.screens.first(where: { $0 !== current }) {
            window.setFrame(CGRect(x: other.frame.midX - 200, y: other.frame.midY - 150, width: 400, height: 300), display: false)
            NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: window)
            try await Task.sleep(for: .milliseconds(30))
            let actual = window.screen!
            precondition(reported == PreviewResolution.displayCanvas(points: actual.frame.size, scale: actual.backingScaleFactor))
        }
        window.contentView = nil
        window.close()
        print("PASS: 1×/2× display sizing, aspect fit/no upscaling, >2560-pixel overviews, cache reuse/resizing, real proxy regeneration, retained full source and native display notifications")
    }
}
