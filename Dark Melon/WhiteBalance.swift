import Foundation

/// Relative linear RGB gains on top of the RAW decoder's white balance.
nonisolated struct WhiteBalance: Codable, Equatable, Sendable {
    var red = 1.0
    var green = 1.0
    var blue = 1.0

    mutating func nudge(dx: Double, dy: Double, colorSpace: ProcessingColorSpace = .sRGB) {
        let distance = hypot(dx, dy)
        guard distance > 0 else { return }
        // Invert the scope's U/right, V/up direction into an RGB adjustment.
        let u = dx / distance, v = -dy / distance
        let rgb = SIMD3(v / 0.877,
                        -(0.299 * v / 0.877 + 0.114 * u / 0.492) / 0.587,
                        u / 0.492)
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
