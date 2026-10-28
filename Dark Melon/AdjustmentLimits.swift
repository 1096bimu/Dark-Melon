import Foundation

/// Processing limits, deliberately separate from the normal slider travel.
/// Finite bounds keep half-float rendering and spatial filter footprints usable.
nonisolated enum AdjustmentLimits {
    static let signedStrength = -16.0...16.0
    static let strength = 0.0...16.0
    static let radius = 0.0...32.0
    static let chroma = 0.0...16.0
    static let density = -1.0...1.0
    static let grainSize = 0.05...16.0
    static let distributionWeight = (1.0 / 256)...256.0
    static let distributionLog = -8.0...8.0
    static let vignetteStops = 0.0...32.0
}
