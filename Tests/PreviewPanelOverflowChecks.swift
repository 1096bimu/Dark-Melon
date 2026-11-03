import AppKit
import CoreImage
import QuartzCore
import SwiftUI
import Observation
@testable import Dark_Melon

@Observable @MainActor private final class PanelState {
    var browser = false
    var panel = true
}

private struct PanelPreview: View {
    let state: PanelState
    let image: CGImage
    let viewport: PreviewViewport

    var body: some View {
        GlassEditorShell(browserVisible: state.browser, panelVisible: state.panel,
            current: nil, resolution: CGSize(width: 800, height: 600), fileSize: nil) {
            HDRImagePreview(sdrImage: image, image: image,
                sourceSize: CGSize(width: 800, height: 600), detail: nil,
                regionChanged: { _ in }, hdr: false, sourceID: UUID(), viewport: viewport,
                cropRatio: nil, cropTransform: .constant(CropTransform()), savedTransform: nil,
                cropChanged: { _ in }, panelEdgePadding: 16, sampleTool: nil, hover: { _ in }, sample: { _, _ in })
                .modifier(PreviewPanelOverflow())
                .padding(16)
        } browser: { Color.clear }
          controls: { Color.clear }
          pending: { EmptyView() }
          leftToolbar: { Text("Left") }
          toolbar: { Text("Top") }
          rightToolbar: { Text("Right") }
    }
}

@main struct PreviewPanelOverflowChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await check() }
            catch { fatalError("Panel overflow checks failed: \(error)") }
            fflush(stdout)
            app.terminate(nil)
        }
        app.run()
    }

    @MainActor static func check() async throws {
        let domain = "DarkMelon.PanelOverflowChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let context = CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8,
            bytesPerRow: 3200, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        let image = context.makeImage()!
        let state = PanelState()
        let viewport = PreviewViewport()
        let host = NSHostingView(rootView: PanelPreview(state: state, image: image, viewport: viewport).defaultAppStorage(defaults))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }

        func displays(_ view: NSView) -> [HDRImagePreview.ImageDisplay] {
            (view as? HDRImagePreview.ImageDisplay).map { [$0] } ?? view.subviews.flatMap(displays)
        }
        for glass in [false, true, false] {
            defaults.set(glass, forKey: "glassEffectsEnabled")
            for (browser, panel) in [(false, true), (true, false), (true, true), (false, false)] {
                state.browser = browser; state.panel = panel
                try await Task.sleep(for: .milliseconds(150))
                host.layoutSubtreeIfNeeded()
                let views = displays(host)
                precondition(views.count == 1, "The backdrop created a second image view")
                let view = views[0]
                let reserved: CGFloat = browser || panel ? 392 : 0
                let expectedWidth: CGFloat = glass ? 1168 : 1168 - reserved
                precondition(abs(view.bounds.width - expectedWidth) < 0.1, "Wrong drawing width")
                precondition(abs(view.navigationBounds.width - (1168 - reserved)) < 0.1, "Navigation area changed")
                precondition(abs(view.navigationBounds.minX - (glass && browser && !panel ? 392 : 0)) < 0.1)
                precondition(abs(view.visibleRect.intersection(view.bounds).width - expectedWidth) < 0.1, "An ancestor clips the overview: glass=\(glass), visible=\(view.visibleRect), bounds=\(view.bounds)")
                view.setNormalizedViewport((2, CGPoint(x: 0.07, y: -0.04)))
                let layers = view.layer!.sublayers!.compactMap { $0 as? CAMetalLayer }
                precondition(layers.count == 2, "Overview was duplicated for the backdrop")
                let overview = layers[1]
                let fit = min(view.navigationBounds.width / 800, view.navigationBounds.height / 600)
                precondition(abs(overview.bounds.width - 800 * fit * 2) < 0.1)
                precondition(abs(overview.position.x - (view.navigationBounds.midX + 800 * fit * 2 * 0.07)) < 0.1)
                precondition(abs(overview.position.y - (view.navigationBounds.midY - 600 * fit * 2 * 0.04)) < 0.1)
                let clip = overview.sublayers!.first!
                let visibleClip = overview.convert(clip.bounds, from: clip)
                let expectedClip = view.detailBounds.offsetBy(dx: -(overview.position.x - overview.bounds.width / 2),
                    dy: -(overview.position.y - overview.bounds.height / 2))
                precondition(abs(visibleClip.minX - expectedClip.minX) < 0.01
                    && abs(visibleClip.minY - expectedClip.minY) < 0.01
                    && abs(visibleClip.width - expectedClip.width) < 0.01
                    && abs(visibleClip.height - expectedClip.height) < 0.01,
                    "Detail extends behind a reserved panel: \(visibleClip) vs \(expectedClip)")
                precondition(clip.masksToBounds)
                let transition = view.convert(view.detailBounds, to: host)
                if glass && panel {
                    precondition(abs(transition.maxX - 808) < 0.1, "Right transition misses panel edge")
                    precondition(view.detailBounds.minX == view.navigationBounds.minX, "Both panels must not reserve the left side")
                } else if glass && browser {
                    precondition(abs(transition.minX - 392) < 0.1, "Left transition misses panel edge")
                } else {
                    precondition(view.detailBounds == view.navigationBounds, "Opaque clipping changed")
                }
            }
        }

        // Request bounds must ignore the additional overview-only drawing area.
        let view = HDRImagePreview.ImageDisplay(viewport: PreviewViewport())
        window.contentView = view
        var region: PreviewRegion?
        view.regionChanged = { region = $0 }
        view.frame = CGRect(x: 0, y: 0, width: 1200, height: 600)
        view.navigationInsets = EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 392)
        view.display(image, sdrImage: image, surface: nil, sdrSurface: nil,
            sourceSize: CGSize(width: 800, height: 600), detail: nil, hdr: false,
            sourceID: UUID(), screenSaverActive: false)
        view.setNormalizedViewport((2, .zero))
        try await Task.sleep(for: .milliseconds(300))
        precondition(region != nil)
        precondition(abs(region!.rect.width - view.navigationBounds.width / (800 * 2)) < 0.001)
        view.navigationInsets = EdgeInsets(top: 0, leading: 392, bottom: 0, trailing: 0)
        view.cropInsets = CGSize(width: 24, height: 72)
        view.configureCrop(ratio: 1, saved: nil)
        view.setNormalizedViewport((1, .zero))
        let crop = view.cropFrame!
        precondition(crop.midX == view.navigationBounds.midX)
        precondition(crop.minX >= view.navigationBounds.minX + 24 && crop.maxX <= view.navigationBounds.maxX - 24)
        print("PASS: glass on/off, left/right/both panels, single overview, unclipped backdrop, shared pan/zoom, detail clipping and request bounds")
    }
}
