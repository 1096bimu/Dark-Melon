#if os(macOS)
import SwiftUI
import QuartzCore

/// Keeps HDR presentation on the image layer while zooming and panning.
struct HDRImagePreview: NSViewRepresentable {
    let image: CGImage
    let hdr: Bool
    let sourceID: UUID
    let pickingWhiteBalance: Bool
    let sample: (CGPoint, CGFloat) -> Void

    func makeNSView(context: Context) -> ImageDisplay { ImageDisplay() }

    func updateNSView(_ view: ImageDisplay, context: Context) {
        view.display(image, hdr: hdr, sourceID: sourceID)
        view.sample = sample
        view.picking = pickingWhiteBalance
    }

    final class ImageDisplay: NSView {
        private let imageLayer = CALayer()
        private let circle = CAShapeLayer()
        private var sampleCenter: CGPoint?
        private var sampleRadius: CGFloat = 0
        var sample: ((CGPoint, CGFloat) -> Void)?
        var picking = false {
            didSet {
                if picking != oldValue {
                    sampleCenter = nil
                    sampleRadius = 0
                    circle.path = nil
                }
            }
        }
        private var sourceID: UUID?
        private var imageSize = CGSize.zero
        private var zoom: CGFloat = 1
        private var offset = CGPoint.zero

        init() {
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
                zoom = 1
                offset = .zero
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

        private func positionImage() {
            guard imageSize.width > 0, imageSize.height > 0 else { return }
            let fit = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
            let size = CGSize(width: imageSize.width * fit * zoom, height: imageSize.height * fit * zoom)
            let limitX = max(0, (size.width - bounds.width) / 2)
            let limitY = max(0, (size.height - bounds.height) / 2)
            offset.x = min(limitX, max(-limitX, offset.x))
            offset.y = min(limitY, max(-limitY, offset.y))
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            imageLayer.frame = CGRect(x: bounds.midX - size.width / 2 + offset.x,
                                      y: bounds.midY - size.height / 2 + offset.y,
                                      width: size.width, height: size.height)
            CATransaction.commit()
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
        }

        override func magnify(with event: NSEvent) { changeZoom(1 + event.magnification, event: event) }
        override func scrollWheel(with event: NSEvent) {
            guard !picking, event.hasPreciseScrollingDeltas,
                  !event.phase.isEmpty || !event.momentumPhase.isEmpty else { return }
            offset.x += event.scrollingDeltaX
            offset.y -= event.scrollingDeltaY
            positionImage()
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
            }
        }
        override func mouseDragged(with event: NSEvent) {
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
