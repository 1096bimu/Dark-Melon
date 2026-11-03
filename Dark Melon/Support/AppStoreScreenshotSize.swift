#if os(macOS) && DEBUG
import AppKit

/// Output pixel dimensions, independent of the display's aspect ratio or Retina scale.
enum AppStoreScreenshotSize: Int, CaseIterable, Identifiable {
    case small = 1280, medium = 1440, large = 2560, largest = 2880

    var id: Int { rawValue }
    var label: String { "\(rawValue) × \(rawValue * 5 / 8) pixels" }

    func frameSize(for window: NSWindow) -> NSSize {
        let scale = window.backingScaleFactor
        return NSSize(width: CGFloat(rawValue) / scale, height: CGFloat(rawValue * 5 / 8) / scale)
    }

    func fits(_ window: NSWindow) -> Bool {
        guard !window.styleMask.contains(.fullScreen), let screen = window.screen else { return false }
        let size = frameSize(for: window)
        let contentMinimum = window.frameRect(forContentRect: NSRect(origin: .zero, size: window.contentMinSize)).size
        return size.width >= max(window.minSize.width, contentMinimum.width)
            && size.height >= max(window.minSize.height, contentMinimum.height)
            && size.width <= screen.visibleFrame.width
            && size.height <= screen.visibleFrame.height
    }

    @MainActor func apply(to window: NSWindow) {
        guard fits(window), let screen = window.screen else { return }
        let size = frameSize(for: window)
        let bounds = screen.visibleFrame
        // Preserve the window's center when possible, keeping the whole frame on screen.
        let origin = NSPoint(
            x: min(max(window.frame.midX - size.width / 2, bounds.minX), bounds.maxX - size.width),
            y: min(max(window.frame.midY - size.height / 2, bounds.minY), bounds.maxY - size.height)
        )
        window.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}
#endif
