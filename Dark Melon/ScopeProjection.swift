import CoreGraphics

/// BT.601 Y′UV on encoded SDR RGB. Screen Y points down; positive V points up.
/// A radius of one on the scope represents 0.75 UV units.
nonisolated enum ScopeProjection {
    static func point(r: Double, g: Double, b: Double) -> CGPoint {
        let y = 0.299*r + 0.587*g + 0.114*b
        return CGPoint(x: 0.492*(b-y)/0.75, y: -0.877*(r-y)/0.75)
    }
}
