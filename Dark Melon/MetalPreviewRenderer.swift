import CoreImage

/// A display graph kept on the GPU. CGImage counterparts are deferred and serve scopes/sampling.
nonisolated struct PreviewSurface: @unchecked Sendable {
    let image: CIImage
    let colorSpace: CGColorSpace
    let hdr: Bool
}

#if os(macOS)
import QuartzCore
import Metal

/// One rendering queue/context per preview view; gestures only move its layers.
nonisolated final class MetalPreviewRenderer: @unchecked Sendable {
    let device = MTLCreateSystemDefaultDevice()
    private let queue = DispatchQueue(label: "DarkMelon.preview.metal", qos: .userInitiated)
    private let lock = NSLock()
    private var generations: [ObjectIdentifier: UUID] = [:]
    private var context: CIContext?
    private var workingSpace: CGColorSpace?
    private var commands: MTLCommandQueue?

    private final class Target: @unchecked Sendable {
        // CAMetalLayer supports background drawable acquisition; all geometry stays on main.
        weak var layer: CAMetalLayer?
        init(_ layer: CAMetalLayer) { self.layer = layer }
    }

    func submit(_ surface: PreviewSurface, to layer: CAMetalLayer,
                install: (@MainActor @Sendable () -> Bool)? = nil) {
        let key = ObjectIdentifier(layer), generation = UUID()
        lock.lock(); generations[key] = generation; lock.unlock()
        let target = Target(layer)
        queue.async { [weak self, target] in
            guard let self, let layer = target.layer, let device, self.isCurrent(key, generation) else { return }
            defer {
                self.lock.lock()
                if self.generations[key] == generation { self.generations.removeValue(forKey: key) }
                self.lock.unlock()
            }
            autoreleasepool {
                if self.workingSpace != surface.colorSpace || self.context == nil {
                    self.context = CIContext(mtlDevice: device, options: [.workingColorSpace: surface.colorSpace,
                        .workingFormat: CIFormat.RGBAf, .cacheIntermediates: true])
                    self.workingSpace = surface.colorSpace
                }
                if self.commands == nil { self.commands = device.makeCommandQueue() }
                guard let drawable = layer.nextDrawable(), let command = self.commands?.makeCommandBuffer(),
                      self.isCurrent(key, generation), let context = self.context else { return }
                let extent = surface.image.extent
                // The AppKit preview layers and detail rectangles use bottom-left coordinates.
                // Preserve that orientation for both the overview and its detail patches.
                let image = surface.image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
                context.render(image, to: drawable.texture, commandBuffer: command,
                               bounds: CGRect(origin: .zero, size: extent.size), colorSpace: surface.colorSpace)
                guard self.isCurrent(key, generation) else { return }
                if let install {
                    // Commit the patch geometry and its first drawable together on main.
                    command.addCompletedHandler { buffer in
                        guard buffer.status == .completed else { return }
                        DispatchQueue.main.async {
                            CATransaction.begin()
                            CATransaction.setDisableActions(true)
                            if install() { drawable.present() }
                            CATransaction.commit()
                        }
                    }
                } else {
                    command.present(drawable)
                }
                command.commit()
            }
        }
    }

    private func isCurrent(_ key: ObjectIdentifier, _ generation: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generations[key] == generation
    }
}
#endif
