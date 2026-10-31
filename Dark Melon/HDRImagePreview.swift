#if os(macOS)
import SwiftUI
import QuartzCore
import CoreImage

enum PreviewSampleTool { case whiteBalance }

/// Owned by the editor so loading placeholders cannot discard the viewport.
final class PreviewViewport {
    let referenceLink = ReferenceViewportLink()
    var zoom: CGFloat = 1
    var offset = CGPoint.zero
}

/// Keeps HDR presentation on the image layer while zooming and panning.
struct HDRImagePreview: NSViewRepresentable {
    @AppStorage("previewMouseControls") private var mouseControls = false
    @AppStorage("previewReverseMouseScroll") private var reverseMouseScroll = false
    let sdrImage: CGImage
    @Environment(\.hdrScreenSaverActive) private var screenSaverActive
    let image: CGImage
    var surface: PreviewSurface? = nil
    var sdrSurface: PreviewSurface? = nil
    let sourceSize: CGSize
    let detail: PreviewDetail?
    let regionChanged: (PreviewRegion?) -> Void
    let hdr: Bool
    let sourceID: UUID
    let viewport: PreviewViewport
    let cropRatio: Double?
    @Binding var cropTransform: CropTransform
    let savedTransform: TransformSettings?
    let cropChanged: ([CGPoint]) -> Void
    let sampleTool: PreviewSampleTool?
    let hover: (CGPoint?) -> Void
    let sample: (CGPoint, CGFloat) -> Void

    func makeNSView(context: Context) -> ImageDisplay { ImageDisplay(viewport: viewport) }

    func updateNSView(_ view: ImageDisplay, context: Context) {
        viewport.referenceLink.main = view
        view.viewportChanged = { [weak view, link = viewport.referenceLink] in if let view { link.changed(view) } }
        view.mouseControls = mouseControls
        view.reverseMouseScroll = reverseMouseScroll
        view.cropChanged = cropChanged
        view.transformChanged = { cropTransform = $0 }
        view.cropTransform = cropTransform
        view.configureCrop(ratio: cropRatio, saved: savedTransform)
        view.hover = hover
        view.regionChanged = regionChanged
        view.display(image, sdrImage: sdrImage, surface: surface, sdrSurface: sdrSurface, sourceSize: sourceSize, detail: detail,
                     hdr: hdr, sourceID: sourceID, screenSaverActive: screenSaverActive)
        view.sample = sample
        view.sampleTool = sampleTool
    }

    final class ImageDisplay: NSView {
        var allowsWhiteBalance = true
        var comparisonClip: CGRect? { didSet { if oldValue != comparisonClip { positionImage() } } }
        var viewportChanged: (() -> Void)?
        var normalizedViewport: (CGFloat, CGPoint) {
            let fit = min(bounds.width / max(1,imageSize.width), bounds.height / max(1,imageSize.height))
            return (zoom, CGPoint(x: offset.x / max(1,imageSize.width * fit * zoom),
                                  y: offset.y / max(1,imageSize.height * fit * zoom)))
        }
        func setNormalizedViewport(_ state: (CGFloat, CGPoint)) {
            let fit = min(bounds.width / max(1,imageSize.width), bounds.height / max(1,imageSize.height))
            zoom = state.0
            offset = CGPoint(x: state.1.x * imageSize.width * fit * zoom, y: state.1.y * imageSize.height * fit * zoom)
            positionImage()
            viewport.zoom = zoom; viewport.offset = offset
        }
        private let imageLayer = CAMetalLayer()
        private let sdrLayer = CAMetalLayer()
        private var detailLayer = CAMetalLayer()
        private var detailGeneration = UUID()
        private let renderer = MetalPreviewRenderer()
        private var displayedImage: CGImage?
        private var displayedSDR: CGImage?
        private var displayedDetail: CGImage?
        private var detailRect: CGRect?
        var regionChanged: ((PreviewRegion?) -> Void)?
        private var pendingRegion: PreviewRegion?
        private var reportedRegion: PreviewRegion?
        private var regionUpdate: DispatchWorkItem?
        private let circle = CAShapeLayer()
        private let cropShade = CAShapeLayer()
        private let cropBorder = CAShapeLayer()
        var cropRatio: Double?
        var cropTransform = CropTransform()
        var transformChanged: ((CropTransform) -> Void)?
        var cropChanged: (([CGPoint]) -> Void)?
        private var pendingCropPolygon: [CGPoint] = []
        private var reportedCropPolygon: [CGPoint] = []
        private var cropUpdateScheduled = false
        private let transformControls = CAShapeLayer()
        private var transformDrag: (CropTransform.Handle, CGPoint, CropTransform)?
        private var restoreCrop: TransformSettings?
        func configureCrop(ratio: Double?, saved: TransformSettings?) {
            if cropRatio == nil, ratio != nil { restoreCrop = saved }
            if cropRatio != nil, ratio == nil {
                zoom = 1; offset = .zero
                rememberViewport()
            }
            cropRatio = ratio
        }

        var reverseMouseScroll = false
        var mouseControls = false {
            didSet {
                toolTip = mouseControls
                    ? String(localized: "Scroll to zoom. Drag to pan. Double-click to zoom in or fit.")
                    : String(localized: "Pinch to zoom. Swipe with two fingers to pan. Double-click to fit.")
            }
        }
        private var panStart: (point: CGPoint, offset: CGPoint)?
        private var contextPoint = CGPoint.zero
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
                    let center = self.imageLayer.position
                    var local = self.cropRatio != nil
                        ? self.cropTransform.unproject(CGPoint(x: point.x - center.x, y: point.y - center.y), in: CropGeometry.frame(in: self.bounds, ratio: self.cropRatio!))
                        : CGPoint(x: point.x - center.x, y: point.y - center.y)
                    if self.cropRatio != nil, let value = local {
                        local = CGPoint(x: value.x - self.offset.x, y: value.y - self.offset.y)
                    }
                    let rect = CGRect(x: -self.imageLayer.bounds.width / 2, y: -self.imageLayer.bounds.height / 2,
                                      width: self.imageLayer.bounds.width, height: self.imageLayer.bounds.height)
                    if let point = local, self.visibleRect.contains(self.convert(window.mouseLocationOutsideOfEventStream, from: nil)), rect.contains(point),
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
            for imageLayer in [imageLayer, sdrLayer, detailLayer] {
                imageLayer.device = renderer.device
                imageLayer.pixelFormat = .rgba16Float
                imageLayer.framebufferOnly = false
                imageLayer.isOpaque = false
            }
            let container = CALayer()
            container.masksToBounds = true
            // Keep the SDR base present throughout interrupted or reversed HDR fades.
            sdrLayer.preferredDynamicRange = .standard
            sdrLayer.contentsHeadroom = 1
            container.addSublayer(sdrLayer)
            container.addSublayer(imageLayer)
            imageLayer.addSublayer(detailLayer)
            circle.strokeColor = NSColor.white.cgColor
            circle.fillColor = NSColor.white.withAlphaComponent(0.12).cgColor
            circle.lineWidth = 2
            circle.shadowColor = NSColor.black.cgColor
            circle.shadowOpacity = 1
            circle.shadowRadius = 2
            container.addSublayer(circle)
            cropShade.fillRule = .evenOdd
            cropShade.fillColor = NSColor.black.withAlphaComponent(0.65).cgColor
            container.addSublayer(cropShade)
            cropBorder.fillColor = nil
            cropBorder.strokeColor = NSColor.white.cgColor
            cropBorder.lineWidth = 1
            container.addSublayer(cropBorder)
            transformControls.fillColor = nil
            transformControls.strokeColor = NSColor.white.cgColor
            transformControls.lineWidth = 2
            transformControls.shadowColor = NSColor.black.cgColor
            transformControls.shadowOpacity = 0.8
            transformControls.shadowRadius = 2
            container.addSublayer(transformControls)
            layer = container
            wantsLayer = true
            toolTip = String(localized: "Pinch to zoom. Swipe with two fingers to pan. Double-click to fit.")
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func display(_ image: CGImage, sdrImage: CGImage, surface: PreviewSurface?, sdrSurface: PreviewSurface?, sourceSize: CGSize, detail: PreviewDetail?,
                     hdr: Bool, sourceID: UUID, screenSaverActive: Bool) {
            if self.sourceID != sourceID {
                self.sourceID = sourceID
                reportedCropPolygon = []
                zoom = viewport.zoom
                offset = viewport.offset
                sampleCenter = nil
                circle.path = nil
            }
            imageSize = sourceSize
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            imageLayer.preferredDynamicRange = hdr ? .high : .standard
            imageLayer.contentsHeadroom = hdr ? CGFloat(image.contentHeadroom) : 1
            if displayedImage !== image {
                displayedImage = image
                render(surface, fallback: image, on: imageLayer, hdr: hdr)
            }
            if displayedSDR !== sdrImage {
                displayedSDR = sdrImage
                render(sdrSurface, fallback: sdrImage, on: sdrLayer, hdr: false)
            }
            let targetOpacity: Float = hdr && screenSaverActive ? 0 : 1
            if imageLayer.opacity != targetOpacity {
                let from = imageLayer.presentation()?.opacity ?? imageLayer.opacity
                imageLayer.opacity = targetOpacity
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = from
                fade.toValue = targetOpacity
                fade.duration = 1
                fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                imageLayer.add(fade, forKey: "screenSaverFade")
            }
            if displayedDetail !== detail?.image {
                displayedDetail = detail?.image
                let generation = UUID()
                detailGeneration = generation
                // Never move an old drawable into a new patch rectangle. Keep the old
                // patch in place until the replacement texture and geometry are ready.
                if let detail {
                    let replacement = CAMetalLayer()
                    replacement.device = renderer.device
                    replacement.pixelFormat = .rgba16Float
                    replacement.framebufferOnly = false
                    replacement.isOpaque = false
                    replacement.presentsWithTransaction = true
                    replacement.preferredDynamicRange = hdr ? .high : .standard
                    replacement.contentsHeadroom = hdr ? CGFloat(detail.image.contentHeadroom) : 1
                    render(detail.surface, fallback: detail.image, on: replacement, hdr: hdr) { [weak self] in
                        guard let self, self.detailGeneration == generation else { return false }
                        self.detailLayer.removeFromSuperlayer()
                        self.detailLayer = replacement
                        self.detailRect = detail.rect
                        self.imageLayer.addSublayer(replacement)
                        replacement.isHidden = self.cropRatio != nil
                        self.positionImage()
                        return true
                    }
                } else {
                    detailRect = nil
                    detailLayer.isHidden = true
                }
            }
            detailLayer.isHidden = detailRect == nil || cropRatio != nil
            positionImage()
            CATransaction.commit()
        }

        private func render(_ surface: PreviewSurface?, fallback: CGImage, on layer: CAMetalLayer, hdr: Bool,
                            install: (@MainActor @Sendable () -> Bool)? = nil) {
            let frame = surface ?? PreviewSurface(image: CIImage(cgImage: fallback),
                colorSpace: fallback.colorSpace ?? CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, hdr: hdr)
            layer.colorspace = frame.colorSpace
            layer.wantsExtendedDynamicRangeContent = frame.hdr
            layer.drawableSize = frame.image.extent.size
            renderer.submit(frame, to: layer, install: install)
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
            let crop = cropRatio.map { CropGeometry.frame(in: bounds, ratio: $0) }
            let fitted = CGSize(width: imageSize.width * fit, height: imageSize.height * fit)
            let size: CGSize
            if let crop {
                if let saved = restoreCrop {
                    let restored = cropTransform.restoredViewport(saved, crop: crop, bounds: bounds, fittedSize: fitted, flippedY: true)
                    zoom = restored.zoom; offset = restored.pan
                    restoreCrop = nil
                }
                let layout = cropTransform.layout(crop: crop, bounds: bounds, fittedSize: fitted, zoom: zoom, pan: offset)
                size = layout.size
                offset = layout.pan
            } else {
                size = CGSize(width: fitted.width * zoom, height: fitted.height * zoom)
                let limitX = max(0, (size.width - bounds.width) / 2)
                let limitY = max(0, (size.height - bounds.height) / 2)
                offset.x = min(limitX, max(-limitX, offset.x))
                offset.y = min(limitY, max(-limitY, offset.y))
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            transformControls.isHidden = crop == nil
            if crop != nil { transformControls.path = CropTransform.controls(in: bounds) }
            cropShade.isHidden = crop == nil
            cropBorder.isHidden = crop == nil
            if let crop {
                let shade = CGMutablePath()
                shade.addRect(bounds)
                shade.addRect(crop)
                cropShade.path = shade
                let border = CGMutablePath()
                border.addRect(crop)
                for fraction in [CGFloat(1.0 / 3), CGFloat(2.0 / 3)] {
                    border.move(to: CGPoint(x: crop.minX + crop.width * fraction, y: crop.minY))
                    border.addLine(to: CGPoint(x: crop.minX + crop.width * fraction, y: crop.maxY))
                    border.move(to: CGPoint(x: crop.minX, y: crop.minY + crop.height * fraction))
                    border.addLine(to: CGPoint(x: crop.maxX, y: crop.minY + crop.height * fraction))
                }
                cropBorder.path = border
            }
            // 1:1 refers to source/output pixels, independent of overview resolution.
            let backingSize = convertToBacking(CGRect(origin: .zero, size: size)).size
            let pixelScale = min(backingSize.width / imageSize.width, backingSize.height / imageSize.height)
            let filter: CALayerContentsFilter = pixelScale >= 1 ? .nearest : .linear
            imageLayer.magnificationFilter = filter
            imageLayer.minificationFilter = filter
            detailLayer.magnificationFilter = filter
            detailLayer.minificationFilter = filter
            imageLayer.bounds = CGRect(origin: .zero, size: size)
            imageLayer.position = crop == nil ? CGPoint(x: bounds.midX + offset.x, y: bounds.midY + offset.y)
                                             : CGPoint(x: bounds.midX, y: bounds.midY)
            imageLayer.transform = crop == nil ? CATransform3DIdentity : cropTransform.matrix(in: crop ?? bounds, pan: offset)
            sdrLayer.bounds = imageLayer.bounds
            sdrLayer.position = imageLayer.position
            sdrLayer.transform = imageLayer.transform
            sdrLayer.magnificationFilter = filter
            sdrLayer.minificationFilter = filter
            if let detailRect {
                detailLayer.frame = CGRect(x: detailRect.minX * size.width, y: detailRect.minY * size.height,
                                           width: detailRect.width * size.width, height: detailRect.height * size.height)
            }
            CATransaction.commit()
            if crop == nil {
                let frame = CGRect(x: imageLayer.position.x - size.width / 2,
                                   y: imageLayer.position.y - size.height / 2, width: size.width, height: size.height)
                let visible = frame.intersection(comparisonClip ?? bounds)
                reportRegion(visible.isEmpty ? nil : PreviewRegion(
                    rect: CGRect(x: (visible.minX - frame.minX) / size.width, y: (visible.minY - frame.minY) / size.height,
                                 width: visible.width / size.width, height: visible.height / size.height),
                    displayPixels: backingSize))
            } else { reportRegion(nil) }
            if let crop {
                pendingCropPolygon = cropTransform.sourcePolygon(crop: crop, bounds: bounds, imageSize: size,
                                                                 center: imageLayer.position, pan: offset, flippedY: true)
                if !cropUpdateScheduled {
                    cropUpdateScheduled = true
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.cropUpdateScheduled = false
                        guard self.cropRatio != nil, self.pendingCropPolygon != self.reportedCropPolygon else { return }
                        self.reportedCropPolygon = self.pendingCropPolygon
                        self.cropChanged?(self.pendingCropPolygon)
                    }
                }
            }
            scheduleHoverUpdate()
        }

        private func reportRegion(_ region: PreviewRegion?) {
            guard pendingRegion != region else { return }
            pendingRegion = region
            regionUpdate?.cancel()
            // Layer geometry updates immediately. Only settled geometry enters SwiftUI,
            // avoiding editor/browser rebuilds and detail-task churn on every gesture event.
            let update = DispatchWorkItem { [weak self] in
                guard let self, self.pendingRegion != self.reportedRegion else { return }
                self.reportedRegion = self.pendingRegion
                self.regionChanged?(self.reportedRegion)
            }
            regionUpdate = update
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: update)
        }

        private func rememberViewport() {
            viewport.zoom = zoom
            viewport.offset = offset
            viewportChanged?()
        }

        private func changeZoom(_ factor: CGFloat, event: NSEvent) {
            guard !picking else { return }
            changeZoom(factor, at: convert(event.locationInWindow, from: nil))
        }

        private var nativeZoom: CGFloat {
            guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else { return 1 }
            let fit = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
            return 1 / (fit * (window?.backingScaleFactor ?? 1))
        }

        private func changeZoom(_ factor: CGFloat, at point: CGPoint, allowBelowFit: Bool = false) {
            let old = zoom
            zoom = min(max(16, nativeZoom * 2), max(allowBelowFit ? min(1, nativeZoom) : 1, zoom * factor))
            let relative = CGPoint(x: point.x - bounds.midX, y: point.y - bounds.midY)
            let anchor = cropRatio == nil ? relative : (cropTransform.unproject(relative, in: CropGeometry.frame(in: bounds, ratio: cropRatio!)) ?? .zero)
            let ratio = zoom / old
            offset.x = (offset.x - anchor.x) * ratio + anchor.x
            offset.y = (offset.y - anchor.y) * ratio + anchor.y
            positionImage()
            rememberViewport()
        }

        override func magnify(with event: NSEvent) {
            if !mouseControls { changeZoom(1 + event.magnification, event: event) }
        }
        override func scrollWheel(with event: NSEvent) {
            guard !picking else { return }
            if mouseControls {
                guard event.scrollingDeltaY != 0, event.momentumPhase.isEmpty else { return }
                // Wheel deltas are accelerated by macOS. Use direction only:
                // six wheel steps double/halve magnification, regardless of speed.
                let direction: CGFloat = event.scrollingDeltaY > 0 ? 1 : -1
                let step = direction * (reverseMouseScroll ? 1 : -1) / 6
                changeZoom(pow(2, step), event: event)
                return
            }
            guard event.hasPreciseScrollingDeltas,
                  !event.phase.isEmpty || !event.momentumPhase.isEmpty else { return }
            let delta = CGPoint(x: event.scrollingDeltaX, y: -event.scrollingDeltaY)
            let movement = cropRatio == nil ? delta : cropTransform.panDelta(delta)
            offset.x += movement.x
            offset.y += movement.y
            positionImage()
            rememberViewport()
        }
        override func mouseDown(with event: NSEvent) {
            let location = convert(event.locationInWindow, from: nil)
            if cropRatio != nil, let handle = CropTransform.hit(location, in: bounds) {
                transformDrag = (handle, location, cropTransform)
                return
            }
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
                if mouseControls, zoom <= 1.001 {
                    changeZoom(max(2, nativeZoom) / zoom, at: location)
                    return
                }
                zoom = 1
                offset = .zero
                positionImage()
                rememberViewport()
            } else if mouseControls {
                panStart = (location, offset)
            }
        }
        override func mouseUp(with event: NSEvent) { transformDrag = nil; panStart = nil }

        override func mouseDragged(with event: NSEvent) {
            scheduleHoverUpdate()
            let point = convert(event.locationInWindow, from: nil)
            if let (handle, start, original) = transformDrag {
                cropTransform = original.dragged(handle, from: start, to: point, in: bounds)
                positionImage()
                rememberViewport()
                transformChanged?(cropTransform)
                return
            }
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
            if mouseControls, let start = panStart {
                let delta = CGPoint(x: point.x - start.point.x, y: point.y - start.point.y)
                let movement = cropRatio == nil ? delta : cropTransform.panDelta(delta)
                offset = CGPoint(x: start.offset.x + movement.x, y: start.offset.y + movement.y)
                positionImage()
                rememberViewport()
            }
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            contextPoint = convert(event.locationInWindow, from: nil)
            let menu = NSMenu()
            menu.autoenablesItems = false
            for (title, action) in [(String(localized: "100% Zoom"), #selector(zoom100)),
                                    (String(localized: "200% Zoom"), #selector(zoom200))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
            menu.addItem(.separator())
            let balance = NSMenuItem(title: String(localized: "White Balance"), action: #selector(sampleContextWhiteBalance), keyEquivalent: "")
            balance.target = self
            balance.isEnabled = allowsWhiteBalance && cropRatio == nil && imageLayer.frame.contains(contextPoint)
            menu.addItem(balance)
            return menu
        }
        @objc private func zoom100() { changeZoom(nativeZoom / zoom, at: contextPoint, allowBelowFit: true) }
        @objc private func zoom200() { changeZoom(2 * nativeZoom / zoom, at: contextPoint, allowBelowFit: true) }
        @objc private func sampleContextWhiteBalance() {
            let rect = imageLayer.frame
            guard rect.width > 0, rect.height > 0, imageSize.width > 0 else { return }
            sampleCenter = nil
            circle.path = nil
            sample?(CGPoint(x: (contextPoint.x - rect.minX) / rect.width,
                            y: (contextPoint.y - rect.minY) / rect.height), 10 / imageSize.width)
        }
    }
}
#endif
