import Foundation

/// Spatial effects share a 6000 × 4000 reference, independent of orientation.
nonisolated enum EffectResolution {
    static let referenceShortSide = 4000.0

    static func scale(shortSide: Double) -> Double {
        max(1, shortSide) / referenceShortSide
    }
}
