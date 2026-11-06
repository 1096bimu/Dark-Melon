import Foundation

/// Spatial enlargement in percent, relative to green and centered on the image.
nonisolated struct ChromaticAberration: Codable, Equatable, Sendable {
    var red = 0.0
    var blue = 0.0
    static let range = -5.0...5.0
    var isIdentity: Bool { red == 0 && blue == 0 }
    var isValid: Bool { red.isFinite && blue.isFinite && Self.range.contains(red) && Self.range.contains(blue) }
}
