import Foundation

/// Relative linear RGB gains on top of the RAW decoder's white balance.
nonisolated struct WhiteBalance: Codable, Equatable, Sendable {
    var red = 1.0
    var green = 1.0
    var blue = 1.0

    mutating func nudge(dx: Double, dy: Double, colorSpace: ProcessingColorSpace = .sRGB) {
        let distance = hypot(dx, dy)
        guard distance > 0 else { return }
        // Lab axes: right is +a (magenta), upward is +b (yellow).
        let neutral = ScopeProjection.linear(SIMD3(50, 0, 0), space: colorSpace)
        let shifted = ScopeProjection.linear(SIMD3(50, dx / distance, -dy / distance), space: colorSpace)
        let rgb = (shifted - neutral) / neutral
        let normalized = rgb / max(abs(rgb.x), abs(rgb.y), abs(rgb.z))
        let direction = (normalized.x, normalized.y, normalized.z)
        let weights = colorSpace.luminance
        let luma = direction.0 * weights.x + direction.1 * weights.y + direction.2 * weights.z
        let strength = 0.88 * distance
        red = min(16, max(1.0 / 16, red * exp((direction.0 - luma) * strength)))
        green = min(16, max(1.0 / 16, green * exp((direction.1 - luma) * strength)))
        blue = min(16, max(1.0 / 16, blue * exp((direction.2 - luma) * strength)))
        // Keep neutral luminance fixed instead of using camera hardware's gain floor.
        let normalization = red * weights.x + green * weights.y + blue * weights.z
        red /= normalization; green /= normalization; blue /= normalization
    }
}
