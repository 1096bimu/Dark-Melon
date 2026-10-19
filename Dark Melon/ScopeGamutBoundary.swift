import CoreGraphics
import Foundation

/// Outer projection of the entire smaller RGB cube onto Y′UV chroma.
/// Inside is not proof of membership: the scope discards lightness.
nonisolated enum ScopeGamutBoundary {
    struct Boundary {
        let name: String
        let points: [CGPoint]
    }
    private static let cache: [ProcessingColorSpace: [Boundary]] = Dictionary(uniqueKeysWithValues:
        ProcessingColorSpace.allCases.map { working in
            let smaller: [ProcessingColorSpace] = working == .rec2020 ? [.sRGB, .displayP3] : working == .displayP3 ? [.sRGB] : []
            return (working, smaller.map { boundary(from: $0, to: working) })
        })
    static func boundaries(in space: ProcessingColorSpace) -> [Boundary] { cache[space]! }

    private static func boundary(from source: ProcessingColorSpace, to target: ProcessingColorSpace) -> Boundary {
        // Sample all six surfaces, including black and white edges, in encoded RGB.
        // Expand by one angular cell and a small radial margin for sampling error.
        let bins = 360, steps = 48
        var radii = [Double](repeating: 0, count: bins)
        for axis in 0..<3 {
            for face in [0.0, 1.0] {
                for i in 0...steps {
                    for j in 0...steps {
                        var components = [CGFloat](repeating: 0, count: 4)
                        components[axis] = face
                        components[(axis + 1) % 3] = Double(i) / Double(steps)
                        components[(axis + 2) % 3] = Double(j) / Double(steps)
                        components[3] = 1
                        guard let c = CGColor(colorSpace: source.encoded, components: components)?.converted(
                            to: target.encoded, intent: .relativeColorimetric, options: nil)?.components else { continue }
                        let r = Double(c[0]), g = Double(c[1]), b = Double(c[2])
                        let point = ScopeProjection.point(r: r, g: g, b: b)
                        let chroma = hypot(point.x, point.y)
                        guard chroma > 0.00001 else { continue }
                        let angle = (atan2(point.y, point.x) / (2 * .pi) + 1).truncatingRemainder(dividingBy: 1)
                        let bin = Int(angle * Double(bins)) % bins
                        for offset in -1...1 {
                            let index = (bin + offset + bins) % bins
                            radii[index] = max(radii[index], min(1, chroma + 0.015))
                        }
                    }
                }
            }
        }
        // Surface samples are uneven in angle. Bridge empty angular cells using
        // the larger neighboring radius, then conservatively widen by three cells.
        let sampled = radii
        for index in radii.indices where sampled[index] == 0 {
            let before = (1..<bins).first { sampled[(index - $0 + bins) % bins] > 0 }!
            let after = (1..<bins).first { sampled[(index + $0) % bins] > 0 }!
            radii[index] = max(sampled[(index - before + bins) % bins], sampled[(index + after) % bins])
        }
        let filled = radii
        for index in radii.indices {
            radii[index] = (-3...3).map { filled[(index + $0 + bins) % bins] }.max()!
        }
        let points = radii.enumerated().map { index, radius in
            let angle = (Double(index) + 0.5) / Double(bins) * 2 * Double.pi
            return CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
        }
        return Boundary(name: source.rawValue, points: points)
    }
}
