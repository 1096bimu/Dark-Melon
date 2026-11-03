import AppKit
@testable import Dark_Melon

@main struct PreviewContextMenuChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: PreviewBackground.preferenceKey)
        defer {
            if let previous { defaults.set(previous, forKey: PreviewBackground.preferenceKey) }
            else { defaults.removeObject(forKey: PreviewBackground.preferenceKey) }
        }
        let context = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 800,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.blue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        let image = context.makeImage()!
        let view = HDRImagePreview.ImageDisplay(viewport: PreviewViewport())
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderBack(nil)
        view.display(image, sdrImage: image, surface: nil, sdrSurface: nil,
            sourceSize: CGSize(width: 200, height: 100), detail: nil, hdr: false,
            sourceID: UUID(), screenSaverActive: false)

        func menu(_ point: CGPoint) -> NSMenu {
            let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1)!
            return view.menu(for: event)!
        }
        let backgroundTitles = PreviewBackground.allCases.map(\.title)
        precondition(menu(CGPoint(x: 200, y: 20)).items.map(\.title) == backgroundTitles)
        precondition(menu(CGPoint(x: 200, y: 200)).items.first?.title == "100% Zoom")
        precondition(menu(CGPoint(x: 200, y: 110)).items.first?.title == "100% Zoom")
        view.setNormalizedViewport((1, CGPoint(x: 0, y: 0.25)))
        precondition(menu(CGPoint(x: 200, y: 110)).items.map(\.title) == backgroundTitles,
            "Image hit testing ignored pan")
        view.setNormalizedViewport((2, .zero))
        precondition(menu(CGPoint(x: 200, y: 20)).items.first?.title == "100% Zoom",
            "Image hit testing ignored zoom")
        view.setNormalizedViewport((1, .zero))
        view.configureCrop(ratio: 2, saved: nil)
        view.cropTransform.rotation = .pi / 4
        view.setNormalizedViewport((1, .zero))
        precondition(menu(CGPoint(x: 20, y: 380)).items.map(\.title) == backgroundTitles,
            "A rotated image's bounding box was mistaken for image content")
        precondition(menu(CGPoint(x: 200, y: 200)).items.first?.title == "100% Zoom")
        precondition(menu(CGPoint(x: 200, y: 200)).items.last?.isEnabled == false,
            "White Balance should remain disabled while cropping")
        view.configureCrop(ratio: nil, saved: nil)
        view.setNormalizedViewport((1, .zero))
        for background in PreviewBackground.allCases {
            let item = menu(CGPoint(x: 200, y: 20)).items.first { $0.representedObject as? String == background.rawValue }!
            precondition(app.sendAction(item.action!, to: item.target, from: item))
            precondition(defaults.string(forKey: PreviewBackground.preferenceKey) == background.rawValue)
            precondition(menu(CGPoint(x: 200, y: 20)).items.first { $0.state == .on }?.title == background.title)
        }
        precondition(PreviewBackground.resolve("", glassEffects: true) == .glass)
        precondition(PreviewBackground.resolve("", glassEffects: false) == .darkGrey)
        precondition(PreviewBackground.resolve("smoke", glassEffects: false) == .glass)
        precondition(PreviewBackground.resolve("black", glassEffects: true) == .darkGrey)
        precondition(PreviewBackground.resolve("white", glassEffects: true) == .lightGrey)
        precondition(PreviewBackground.darkGrey.greyLevel == 0.06)
        precondition(PreviewBackground.grey.greyLevel == 0.18)
        precondition(PreviewBackground.lightGrey.greyLevel == 0.9)
        window.close()
        print("PASS: image/background menus, zoom/pan/rotated-crop hit testing, background selection and checkmarks, existing Glass Effects defaults")
    }
}
