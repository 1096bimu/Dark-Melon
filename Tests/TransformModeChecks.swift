import AppKit
import SwiftUI
import Observation
import QuartzCore
@testable import Dark_Melon

@Observable @MainActor private final class TransformProbeState {
    var ratio = 5.0
    var transforming = true
    var preview = CGRect.zero
}

private struct TransformProbeRoot: View {
    let state: TransformProbeState
    var body: some View {
        GlassEditorShell(browserVisible: false, panelVisible: true, current: nil,
            resolution: .zero, fileSize: nil,
            cropRatioPosition: state.transforming ? Binding(get: { state.ratio }, set: { state.ratio = $0 }) : nil) {
                Color.gray.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { state.preview = $0 }
            } browser: { Color.clear }
              controls: { Color.black }
              pending: { EmptyView() }
              leftToolbar: { Text("Left") }
              toolbar: { Text("Top") }
              rightToolbar: { Text("Right") }
    }
}

@main struct TransformModeChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await runChecks() }
            catch { fatalError("Transform checks failed: \(error)") }
            fflush(stdout)
            app.terminate(nil)
        }
        app.run()
    }

    @MainActor static func runChecks() async throws {
        let app = NSApplication.shared
        for i in 0...1100 {
            let position = Double(i) / 100
            precondition(abs(CropGeometry.position(for: CropGeometry.ratio(at: position)) - position) < 1e-10)
        }
        let state = TransformProbeState()
        let host = NSHostingView(rootView: TransformProbeRoot(state: state))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(150))
        precondition(state.preview == CGRect(x: 0, y: 0, width: 808, height: 600), "Transform insets clipped the image viewport")

        func send(_ events: [(NSEvent.EventType, CGFloat, CGFloat)]) async throws {
            for (type, x, y) in events {
                let event = NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: 600 - y), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                app.postEvent(event, atStart: false)
            }
            while let event = app.nextEvent(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp],
                until: Date(timeIntervalSinceNow: 0.02), inMode: .default, dequeue: true) {
                app.sendEvent(event)
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        try await send([(.leftMouseDown, 664, 570), (.leftMouseUp, 664, 570)])
        precondition(state.ratio == 6, "Ratio label click did not snap exactly")
        try await send([(.leftMouseDown, 600, 570), (.leftMouseDragged, 608, 570), (.leftMouseDragged, 632, 570), (.leftMouseUp, 632, 570)])
        precondition(abs(state.ratio - state.ratio.rounded()) > 0.1, "Free drag snapped to a named ratio")

        host.layoutSubtreeIfNeeded()
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/TransformModeChecks.png"))
        state.transforming = false
        try await Task.sleep(for: .milliseconds(100))
        precondition(state.preview == CGRect(x: 0, y: 0, width: 808, height: 600), "Commit did not restore the normal preview area")

        let context = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 800,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = context.makeImage()!
        let display = HDRImagePreview.ImageDisplay(viewport: PreviewViewport())
        display.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        display.display(image, sdrImage: image, surface: nil, sdrSurface: nil, sourceSize: CGSize(width: 200, height: 100),
            detail: nil, hdr: false, sourceID: UUID(), screenSaverActive: false)
        display.setNormalizedViewport((3, .zero))
        display.cropInsets = CGSize(width: 24, height: 72)
        display.configureCrop(ratio: 2, saved: nil)
        display.layoutSubtreeIfNeeded()
        precondition(display.normalizedViewport.0 == 1, "Transform inherited the previous photo zoom")
        let crop = display.cropFrame!
        precondition(crop.minX >= 24 && crop.maxX <= 376 && crop.minY >= 72 && crop.maxY <= 328,
            "Crop frame entered the reserved pill area")
        let shade = display.layer!.sublayers!.compactMap { $0 as? CAShapeLayer }.first { $0.fillRule == .evenOdd }!
        func shaded(_ point: CGPoint) -> Bool {
            shade.path!.contains(shade.convert(point, from: display.layer), using: .evenOdd)
        }
        precondition(!shaded(CGPoint(x: 5, y: 5)), "Empty background was darkened")
        display.setNormalizedViewport((2, .zero))
        precondition(display.cropFrame == crop, "Zoom moved the crop frame into the safe area")
        precondition(shaded(CGPoint(x: 10, y: 40)), "Zoomed image could not enter the inset area")
        precondition(!shaded(CGPoint(x: 200, y: 200)), "Crop interior was darkened")
        precondition(!shaded(CGPoint(x: 5, y: 5)), "Empty canvas outside the zoomed image was darkened")
        var commits = 0
        var committedPolygon: [CGPoint] = []
        display.cropChanged = { committedPolygon = $0 }
        display.commitTransform = { commits += 1 }
        let doubleClick = NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 200, y: 200), modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 2, pressure: 1)!
        display.mouseDown(with: doubleClick)
        precondition(commits == 1 && committedPolygon.count == 4, "Double click did not commit the current transform")
        window.close()
        print("PASS: full image viewport, crop-only safe area, image-only shading, inset zoom coverage, ratio gestures, entry zoom and double-click commit")
    }
}
