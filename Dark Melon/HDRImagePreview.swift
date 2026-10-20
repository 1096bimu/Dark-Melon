#if os(macOS)
import SwiftUI
import QuartzCore

enum PreviewSampleTool { case whiteBalance }

/// Owned by the editor so loading placeholders cannot discard the viewport.
final class PreviewViewport {
    var zoom: CGFloat = 1
    var offset = CGPoint.zero
}

/// Keeps HDR presentation on the image layer while zooming and panning.
struct HDRImagePreview: NSViewRepresentable {
    let image: CGImage
    let hdr: Bool
    let sourceID: UUID
    let viewport: PreviewViewport
    let sampleTool: PreviewSampleTool?
    let hover: (CGPoint?) -> Void
    let sample: (CGPoint, CGFloat) -> Void

    func makeNSView(context: Context) -> ImageDisplay { ImageDisplay(viewport: viewport) }

    func updateNSView(_ view: ImageDisplay, context: Context) {
        view.hover = hover
        view.display(image, hdr: hdr, sourceID: sourceID)
        view.sample = sample
        view.sampleTool = sampleTool
    }

    final class ImageDisplay: NSView {
        private let imageLayer = CALayer()
        private let circle = CAShapeLayer()
        private var sampleCenter: CGPoint?
        private var sampleRadius: CGFloat = 0
        var sample: ((CGPoint, CGFloat) -> Void)?
        var hover: ((CGPoint?) -> Void)?
        private var hoverTracking: NSTrackingArea?
        private var hoverUpdateScheduled = false
        private var reportedHover: CGPoint?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let hoverTracking { removeTrackingArea(hoverTracking) }
            let tracking = NSTrackingArea(rect: .zero,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                owner: self, userInfo: nil)
            addTrackingArea(tracking)
            hoverTracking = tracking
            scheduleHoverUpdate()
        }

        override func mouseEntered(with event: NSEvent) { scheduleHoverUpdate() }
        override func mouseMoved(with event: NSEvent) { scheduleHoverUpdate() }
        override func mouseExited(with event: NSEvent) {
            reportedHover = nil
            hover?(nil)
        }

        private func scheduleHoverUpdate() {
            guard !hoverUpdateScheduled else { return }
            hoverUpdateScheduled = true
            // Also called by layout/updateNSView: defer SwiftUI state changes and coalesce events.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.hoverUpdateScheduled = false
                var location: CGPoint?
                if let window = self.window, window.isKeyWindow {
                    let point = self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
                    let rect = self.imageLayer.frame
                    if self.visibleRect.contains(point), rect.contains(point),
                       rect.width > 0, rect.height > 0, self.imageSize.width > 0, self.imageSize.height > 0 {
                        // Pixel centers suppress repeated sampling within the same image pixel.
                        let x = floor((point.x - rect.minX) / rect.width * self.imageSize.width)
                        let y = floor((point.y - rect.minY) / rect.height * self.imageSize.height)
                        location = CGPoint(x: (x + 0.5) / self.imageSize.width,
                                           y: (y + 0.5) / self.imageSize.height)
                    }
                }
                if location != self.reportedHover {
                    self.reportedHover = location
                    self.hover?(location)
                }
            }
        }

        private var picking: Bool { sampleTool != nil }
        var sampleTool: PreviewSampleTool? {
            didSet {
                if sampleTool != oldValue {
                    sampleCenter = nil
                    sampleRadius = 0
                    circle.path = nil
                }
            }
        }
        private var sourceID: UUID?
        private var imageSize = CGSize.zero
        private let viewport: PreviewViewport
        private var zoom: CGFloat
        private var offset: CGPoint

        init(viewport: PreviewViewport) {
            self.viewport = viewport
            zoom = viewport.zoom
            offset = viewport.offset
            super.init(frame: .zero)
            let container = CALayer()
            container.masksToBounds = true
            container.addSublayer(imageLayer)
            circle.strokeColor = NSColor.white.cgColor
            circle.fillColor = NSColor.white.withAlphaComponent(0.12).cgColor
            circle.lineWidth = 2
            circle.shadowColor = NSColor.black.cgColor
            circle.shadowOpacity = 1
            circle.shadowRadius = 2
            container.addSublayer(circle)
            layer = container
            wantsLayer = true
            toolTip = "Pinch to zoom. Swipe with two fingers to pan. Double-click to fit."
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func display(_ image: CGImage, hdr: Bool, sourceID: UUID) {
            if self.sourceID != sourceID {
                self.sourceID = sourceID
                zoom = viewport.zoom
                offset = viewport.offset
                sampleCenter = nil
                circle.path = nil
            }
            imageSize = CGSize(width: image.width, height: image.height)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            imageLayer.preferredDynamicRange = hdr ? .high : .standard
            imageLayer.contentsHeadroom = hdr ? CGFloat(image.contentHeadroom) : 1
            imageLayer.contents = image
            positionImage()
            CATransaction.commit()
        }

        override func layout() {
            super.layout()
            positionImage()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            positionImage()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            positionImage()
        }

        private func positionImage() {
            guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else { return }
            let fit = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
            let size = CGSize(width: imageSize.width * fit * zoom, height: imageSize.height * fit * zoom)
            let limitX = max(0, (size.width - bounds.width) / 2)
            let limitY = max(0, (size.height - bounds.height) / 2)
            offset.x = min(limitX, max(-limitX, offset.x))
            offset.y = min(limitY, max(-limitY, offset.y))
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // 1:1 means one preview image pixel per physical display pixel.
            let backingSize = convertToBacking(CGRect(origin: .zero, size: size)).size
            let pixelScale = min(backingSize.width / imageSize.width, backingSize.height / imageSize.height)
            let filter: CALayerContentsFilter = pixelScale >= 1 ? .nearest : .linear
            imageLayer.magnificationFilter = filter
            imageLayer.minificationFilter = filter
            imageLayer.frame = CGRect(x: bounds.midX - size.width / 2 + offset.x,
                                      y: bounds.midY - size.height / 2 + offset.y,
                                      width: size.width, height: size.height)
            CATransaction.commit()
            scheduleHoverUpdate()
        }

        private func rememberViewport() {
            viewport.zoom = zoom
            viewport.offset = offset
        }

        private func changeZoom(_ factor: CGFloat, event: NSEvent) {
            guard !picking else { return }
            let old = zoom
            zoom = min(16, max(1, zoom * factor))
            let point = convert(event.locationInWindow, from: nil)
            let ratio = zoom / old
            offset.x = (offset.x - (point.x - bounds.midX)) * ratio + point.x - bounds.midX
            offset.y = (offset.y - (point.y - bounds.midY)) * ratio + point.y - bounds.midY
            positionImage()
            rememberViewport()
        }

        override func magnify(with event: NSEvent) { changeZoom(1 + event.magnification, event: event) }
        override func scrollWheel(with event: NSEvent) {
            guard !picking, event.hasPreciseScrollingDeltas,
                  !event.phase.isEmpty || !event.momentumPhase.isEmpty else { return }
            offset.x += event.scrollingDeltaX
            offset.y -= event.scrollingDeltaY
            positionImage()
            rememberViewport()
        }
        override func mouseDown(with event: NSEvent) {
            if picking {
                let point = convert(event.locationInWindow, from: nil)
                let rect = imageLayer.frame
                if let center = sampleCenter, sampleRadius >= 2 {
                    sample?(CGPoint(x: (center.x - rect.minX) / rect.width,
                                    y: (center.y - rect.minY) / rect.height), sampleRadius / rect.width)
                    sampleCenter = nil
                    circle.path = nil
                } else if rect.contains(point) {
                    sampleCenter = point
                    sampleRadius = 0
                }
                return
            }
            if event.clickCount == 2 {
                zoom = 1
                offset = .zero
                positionImage()
                rememberViewport()
            }
        }
        override func mouseDragged(with event: NSEvent) {
            scheduleHoverUpdate()
            let point = convert(event.locationInWindow, from: nil)
            if picking {
                guard let center = sampleCenter else { return }
                sampleRadius = hypot(point.x - center.x, point.y - center.y)
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                circle.path = CGPath(ellipseIn: CGRect(x: center.x - sampleRadius, y: center.y - sampleRadius,
                                                      width: sampleRadius * 2, height: sampleRadius * 2), transform: nil)
                CATransaction.commit()
                return
            }
        }
    }
}
#endif
