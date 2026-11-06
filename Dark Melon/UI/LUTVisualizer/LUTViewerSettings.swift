#if os(macOS)
import Foundation
import simd

nonisolated struct LUTViewerSettings: Equatable, Sendable {
    static let densityLevels: [Double] = [17, 25, 33, 49, 65]
    enum Mode: String, CaseIterable, Sendable { case cube = "Cube", rays = "Rays", slice = "Slice" }
    var mode: Mode = .cube
    var density: Double = 17
    var pointSize: Double = 0.5
    var opacity: Double = 1
    var background: Double = 0.035
    var region = "All"
    var neutrals = false
    enum Clipping: String, CaseIterable, Sendable {
        case off = "Off", highlight = "Clipped", unclipped = "Not Clipped"
    }
    var clipping: Clipping = .off
    var vectors = false
    var autoRotate = false
    var showRamp = true
    var axis = 2
    var slice: Float = 0.5

    func pointRadius(shortEdge: Double, scale: Double) -> Double {
        pointSize / 100 * max(1, shortEdge) * scale
    }
}


#endif
