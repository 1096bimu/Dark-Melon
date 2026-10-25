import SwiftUI
import simd

/// Only marker overlays observe pointer changes; the editor and graph backgrounds do not.
@Observable final class PreviewHoverState {
    var position: CGPoint?
}

struct HoverPixelOverlay: View {
    @Environment(PreviewHoverState.self) private var hover
    let source: CGImage?
    let revision: UUID?
    let space: ProcessingColorSpace
    var encoded = false
    var transform: TransformSettings? = nil
    let draw: (inout GraphicsContext, CGSize, SIMD3<Double>) -> Void
    @State private var sampler = ScopeHoverSampler()
    @State private var result: SIMD3<Double>?
    @State private var completed: Request?

    private struct Request: Equatable {
        let position: CGPoint?
        let revision: UUID?
        let source: ObjectIdentifier?
        let space: ProcessingColorSpace
        let encoded: Bool
    }
    private var request: Request {
        var position = hover.position
        if let point = position, let transform {
            let source = transform.sourcePoint(CGPoint(x: point.x, y: 1 - point.y))
            position = CGPoint(x: source.x, y: 1 - source.y)
        }
        return Request(position: position, revision: revision, source: source.map(ObjectIdentifier.init),
                       space: space, encoded: encoded)
    }
    var body: some View {
        let current = request
        Canvas { context, size in
            if completed == current, let result { draw(&context, size, result) }
        }
        .allowsHitTesting(false)
        .task(id: current) {
            guard let source, let revision, let position = current.position else { result = nil; return }
            do {
                let rgb = try await sampler.sampleRGB(source, revision: revision, position: position,
                                                      space: space, encoded: encoded)
                try Task.checkCancellation()
                result = rgb
                completed = current
            } catch is CancellationError {
            } catch { result = nil }
        }
    }
}

struct HuePixelOverlay: View {
    let source: CGImage?
    let revision: UUID
    let space: ProcessingColorSpace
    let transform: TransformSettings?
    let lightness: Bool
    let maximum: Double
    let scale: Double
    var body: some View {
        HoverPixelOverlay(source: source, revision: revision, space: space, transform: transform) { context, size, rgb in
            let matrix = ScopeProjection.matrix(.sRGB).inverse * ScopeProjection.matrix(space)
            let lab = OKLabVertexWarp.lab(matrix * rgb)
            let chroma = hypot(lab.y, lab.z)
            guard chroma > 0.00001 else { return }
            let hue = atan2(lab.z, lab.y) / (2 * .pi)
            let x = hue - floor(hue)
            let y = 1 - (lightness ? lab.x / scale : chroma / maximum)
            for copy in -1...1 {
                ScopePixelMarker.draw(in: &context, at: CGPoint(x: (x + Double(copy)) * size.width, y: min(1, max(0, y)) * size.height))
            }
        }
    }
}
