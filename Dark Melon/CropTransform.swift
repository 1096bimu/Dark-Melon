import SwiftUI
import QuartzCore

/// Temporary preview geometry, independent of the saved development recipe.
struct CropTransform: Equatable {
    var rotation: CGFloat = 0
    var horizontal: CGFloat = 0
    var vertical: CGFloat = 0

    enum Handle { case rotation, horizontal, vertical }

    static func radius(in bounds: CGRect) -> CGFloat { min(bounds.width, bounds.height) * 0.36 }

    static func hit(_ point: CGPoint, in bounds: CGRect) -> Handle? {
        let x = point.x - bounds.midX, y = point.y - bounds.midY
        let r = radius(in: bounds)
        // Leave a small gap at the center so the two axes are unambiguous.
        if abs(hypot(x, y) - r) < 14 { return .rotation }
        if abs(x) < 12, abs(y) > 16, abs(y) < r - 18 { return .vertical }
        if abs(y) < 12, abs(x) > 16, abs(x) < r - 18 { return .horizontal }
        return nil
    }

    func dragged(_ handle: Handle, from start: CGPoint, to point: CGPoint, in bounds: CGRect) -> Self {
        var result = self
        switch handle {
        case .rotation:
            let a = atan2(start.y - bounds.midY, start.x - bounds.midX)
            let b = atan2(point.y - bounds.midY, point.x - bounds.midX)
            result.rotation += atan2(sin(b - a), cos(b - a))
        case .vertical:
            result.vertical = min(0.3, max(-0.3, vertical + (point.y - start.y) / Self.radius(in: bounds) * 0.3))
        case .horizontal:
            result.horizontal = min(0.3, max(-0.3, horizontal + (point.x - start.x) / Self.radius(in: bounds) * 0.3))
        }
        return result
    }

    func matrix(in bounds: CGRect, pan: CGPoint = .zero) -> CATransform3D {
        let reference = max(bounds.width, bounds.height) / 2
        var matrix = CATransform3DIdentity
        matrix.m11 = cos(rotation); matrix.m12 = sin(rotation)
        matrix.m21 = -sin(rotation); matrix.m22 = cos(rotation)
        matrix.m14 = horizontal / max(1, reference)
        matrix.m24 = vertical / max(1, reference)
        return CATransform3DConcat(CATransform3DMakeTranslation(pan.x, pan.y, 0), matrix)
    }

    /// Inverse planar projection, relative to the image center. Also used for picking.
    func unproject(_ point: CGPoint, in bounds: CGRect) -> CGPoint? {
        let x = cos(rotation) * point.x + sin(rotation) * point.y
        let y = -sin(rotation) * point.x + cos(rotation) * point.y
        let reference = max(1, max(bounds.width, bounds.height) / 2)
        let w = 1 - (horizontal * x + vertical * y) / reference
        guard w > 0.05 else { return nil }
        return CGPoint(x: x / w, y: y / w)
    }

    /// Crop corners mapped back into the full photo, in normalized top-left coordinates.
    func sourcePolygon(crop: CGRect, bounds: CGRect, imageSize: CGSize,
                       center: CGPoint, pan: CGPoint = .zero, flippedY: Bool = false) -> [CGPoint] {
        guard imageSize.width > 0, imageSize.height > 0 else { return [] }
        let corners = [CGPoint(x: crop.minX, y: crop.minY), CGPoint(x: crop.maxX, y: crop.minY),
                       CGPoint(x: crop.maxX, y: crop.maxY), CGPoint(x: crop.minX, y: crop.maxY)]
        let points = corners.compactMap { corner -> CGPoint? in
            guard let point = unproject(CGPoint(x: corner.x - center.x, y: corner.y - center.y), in: crop) else { return nil }
            let y = (point.y - pan.y) / imageSize.height + 0.5
            return CGPoint(x: (point.x - pan.x) / imageSize.width + 0.5, y: flippedY ? 1 - y : y)
        }
        guard points.count == 4 else { return [] }
        return flippedY ? [points[3], points[2], points[1], points[0]] : points
    }

    struct Layout {
        let size: CGSize
        let pan: CGPoint
        let minimumZoom: CGFloat
    }

    /// Coverage depends only on the fixed inverse-projected crop, never on pan or previous frames.
    func layout(crop: CGRect, bounds: CGRect, fittedSize: CGSize, zoom: CGFloat, pan: CGPoint) -> Layout {
        let corners = [CGPoint(x: crop.minX, y: crop.minY), CGPoint(x: crop.maxX, y: crop.minY),
                       CGPoint(x: crop.maxX, y: crop.maxY), CGPoint(x: crop.minX, y: crop.maxY)]
        let points = corners.compactMap { unproject(CGPoint(x: $0.x - bounds.midX, y: $0.y - bounds.midY), in: crop) }
        guard points.count == 4, fittedSize.width > 0, fittedSize.height > 0 else {
            return Layout(size: fittedSize, pan: .zero, minimumZoom: 1)
        }
        let minX = points.map(\.x).min()!, maxX = points.map(\.x).max()!
        let minY = points.map(\.y).min()!, maxY = points.map(\.y).max()!
        let minimum = max(1, max((maxX - minX) / fittedSize.width, (maxY - minY) / fittedSize.height))
        let scale = max(minimum, zoom)
        let size = CGSize(width: fittedSize.width * scale, height: fittedSize.height * scale)
        let clamped = CGPoint(x: min(minX + size.width / 2, max(maxX - size.width / 2, pan.x)),
                              y: min(minY + size.height / 2, max(maxY - size.height / 2, pan.y)))
        return Layout(size: size, pan: clamped, minimumZoom: minimum)
    }

    /// Convert screen-axis panning to the unprojected image plane.
    func panDelta(_ delta: CGPoint) -> CGPoint {
        CGPoint(x: cos(rotation) * delta.x + sin(rotation) * delta.y,
                y: -sin(rotation) * delta.x + cos(rotation) * delta.y)
    }

    /// Recover the editor viewport from a saved source quad at any window size.
    func restoredViewport(_ saved: TransformSettings, crop: CGRect, bounds: CGRect,
                          fittedSize: CGSize, flippedY: Bool) -> (zoom: CGFloat, pan: CGPoint) {
        let projected = sourcePolygon(crop: crop, bounds: bounds, imageSize: fittedSize,
                                      center: CGPoint(x: bounds.midX, y: bounds.midY))
        guard projected.count == 4 else { return (1, .zero) }
        let source = saved.points.map { CGPoint(x: $0.x, y: flippedY ? 1 - $0.y : $0.y) }
        let projectedWidth = projected.map(\.x).max()! - projected.map(\.x).min()!
        let sourceWidth = source.map(\.x).max()! - source.map(\.x).min()!
        let zoom = projectedWidth / max(1e-9, sourceWidth)
        let pan = CGPoint(x: (projected.map(\.x).min()! - 0.5) * fittedSize.width
                            - (source.map(\.x).min()! - 0.5) * fittedSize.width * zoom,
                          y: (projected.map(\.y).min()! - 0.5) * fittedSize.height
                            - (source.map(\.y).min()! - 0.5) * fittedSize.height * zoom)
        return (zoom, pan)
    }

    static func controls(in bounds: CGRect) -> CGPath {
        let r = radius(in: bounds), x = bounds.midX, y = bounds.midY
        let path = CGMutablePath()
        path.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        for sign in [CGFloat(-1), CGFloat(1)] {
            path.move(to: CGPoint(x: x + sign * 16, y: y))
            path.addLine(to: CGPoint(x: x + sign * (r - 18), y: y))
            path.move(to: CGPoint(x: x, y: y + sign * 16))
            path.addLine(to: CGPoint(x: x, y: y + sign * (r - 18)))
        }
        return path
    }
}
