import AppKit
import CoreImage
import QuartzCore
@testable import Dark_Melon

@main struct PreviewPresentationChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await check() }
            catch { fatalError("Preview presentation failed: \(error)") }
            fflush(stdout)
            app.terminate(nil)
        }
        app.run()
    }

    @MainActor static func check() async throws {
        let renderer = MetalPreviewRenderer()
        let layer = CAMetalLayer()
        layer.device = renderer.device
        layer.pixelFormat = .rgba16Float
        layer.framebufferOnly = false
        layer.drawableSize = CGSize(width: 128, height: 128)
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 128, height: 128))
        view.wantsLayer = true
        view.layer = layer
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        var installed: [Int] = []
        for frame in 0..<40 {
            let image = CIImage(color: CIColor(red: Double(frame + 1) / 40, green: 0.3, blue: 0.4))
                .cropped(to: CGRect(x: 0, y: 0, width: 128, height: 128))
            renderer.submit(PreviewSurface(image: image, colorSpace: ProcessingColorSpace.sRGB.linear, hdr: false),
                to: layer, install: { installed.append(frame); return true })
        }
        for _ in 0..<300 {
            if !installed.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(installed == [39], "A superseded frame was installed: \(installed)")
        try await Task.sleep(for: .milliseconds(100))
        precondition(installed == [39])
        print("PASS: rapid overview replacement presents only the current completed frame")
    }
}
