import Foundation
import CoreImage
import simd

/// A normalized source quadrilateral plus the editor controls that produced it.
/// Point order is top-left, top-right, bottom-right, bottom-left, independent of platform.
nonisolated struct TransformSettings: Codable, Equatable, Sendable {
    var points: [CGPoint]
    var ratioPosition: Double
    var rotation: Double
    var horizontal: Double
    var vertical: Double

    var aspect: Double { CropGeometry.ratio(at: ratioPosition) }

    func reoriented(from old: SourceOrientation, to new: SourceOrientation) -> Self {
        guard old != new, points.count == 4 else { return self }
        func moved(_ point: CGPoint) -> CGPoint { new.apply(to: old.sourcePoint(point)) }
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
        let movedCorners = corners.map(moved)
        let origin = movedCorners[0]
        let x = CGPoint(x: movedCorners[1].x - origin.x, y: movedCorners[1].y - origin.y)
        let y = CGPoint(x: movedCorners[3].x - origin.x, y: movedCorners[3].y - origin.y)
        var result = self
        result.points = corners.map { corner in moved(points[movedCorners.firstIndex(of: corner)!]) }
        if abs(x.y) > 0.5 { result.ratioPosition = CropGeometry.position(for: 1 / aspect) }
        result.rotation = (x.x * y.y - x.y * y.x) * rotation
        // Perspective axes use the preview's bottom-left coordinate convention.
        result.horizontal = x.x * horizontal - y.x * vertical
        result.vertical = -x.y * horizontal + y.y * vertical
        return result
    }

    enum ResolutionEstimate { case conservative, maximum }

    func resolution(width: Int, height: Int, estimate: ResolutionEstimate = .conservative) -> CGSize {
        guard points.count == 4 else { return CGSize(width: width, height: height) }
        func length(_ a: Int, _ b: Int) -> Double {
            hypot((points[a].x - points[b].x) * Double(width), (points[a].y - points[b].y) * Double(height))
        }
        let edges = [length(0, 1) / aspect, length(3, 2) / aspect,
                     length(0, 3), length(1, 2)]
        let projectedHeight = estimate == .maximum ? edges.max()! : edges.min()!
        // Normalized corner roundoff must not shave off a pixel after a quarter-turn.
        let outputHeight = max(1, floor(projectedHeight + 1e-6))
        return CGSize(width: max(1, floor(outputHeight * aspect + 1e-6)), height: outputHeight)
    }

    var isValid: Bool {
        guard points.count == 4, ratioPosition.isFinite, CropGeometry.positionRange.contains(ratioPosition),
              rotation.isFinite, abs(rotation) < 1e6,
              horizontal.isFinite, abs(horizontal) <= 0.3,
              vertical.isFinite, abs(vertical) <= 0.3,
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (-0.00001...1.00001).contains($0.x) && (-0.00001...1.00001).contains($0.y) }) else { return false }
        // Reject collapsed, reversed or self-intersecting quadrilaterals.
        return (0..<4).allSatisfy { i in
            let a = points[i], b = points[(i+1)%4], c = points[(i+2)%4]
            return (b.x-a.x)*(c.y-b.y) - (b.y-a.y)*(c.x-b.x) > 1e-10
        }
    }

    func apply(to image: CIImage) throws -> CIImage {
        guard isValid else { throw RecipeError.invalid }
        let extent = image.extent
        func vector(_ index: Int) -> CIVector {
            CIVector(x: extent.minX + points[index].x * extent.width,
                     y: extent.minY + (1 - points[index].y) * extent.height)
        }
        let corrected = image.applyingFilter("CIPerspectiveCorrection", parameters: [
            "inputTopLeft": vector(0), "inputTopRight": vector(1),
            "inputBottomRight": vector(2), "inputBottomLeft": vector(3), "inputCrop": true
        ])
        let size = resolution(width: Int(extent.width), height: Int(extent.height), estimate: .maximum)
        let rect = corrected.extent
        guard rect.width > 0, rect.height > 0, !rect.isInfinite else { throw RecipeError.invalid }
        return corrected.transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            .transformed(by: CGAffineTransform(scaleX: size.width / rect.width, y: size.height / rect.height))
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    /// Homography from the final rectangle back to the source, for hover and sampling.
    var sourceHomography: simd_double3x3 {
        let a = points[0], b = points[1], c = points[2], d = points[3]
        let dx1 = b.x-c.x, dx2 = d.x-c.x, dx3 = a.x-b.x+c.x-d.x
        let dy1 = b.y-c.y, dy2 = d.y-c.y, dy3 = a.y-b.y+c.y-d.y
        let determinant = dx1*dy2-dx2*dy1
        let g = (dx3*dy2-dx2*dy3) / determinant
        let h = (dx1*dy3-dx3*dy1) / determinant
        return simd_double3x3(columns: (
            SIMD3(b.x-a.x+g*b.x, b.y-a.y+g*b.y, g),
            SIMD3(d.x-a.x+h*d.x, d.y-a.y+h*d.y, h),
            SIMD3(a.x, a.y, 1)))
    }

    func sourcePoint(_ point: CGPoint) -> CGPoint {
        let projected = sourceHomography * SIMD3(point.x, point.y, 1)
        return CGPoint(x: projected.x / projected.z, y: projected.y / projected.z)
    }
}
