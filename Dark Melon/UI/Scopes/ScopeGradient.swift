// Density palettes adapted from Audio Analyzer/ColorGradient.swift.

import SwiftUI

/// One control point in a colormap.
nonisolated struct ScopeGradientStop {
    /// Color in sRGB, each component 0…255.
    var r: UInt8
    var g: UInt8
    var b: UInt8
    /// Where this stop sits on the 0…1 intensity axis.
    var location: Float

    init(_ r: UInt8, _ g: UInt8, _ b: UInt8, at location: Float) {
        self.r = r; self.g = g; self.b = b; self.location = location
    }
}

nonisolated enum ScopeGradient: String, CaseIterable, Identifiable, Sendable {
    case inferno
    case Bochi
    case CRYCHIC
    case Kumiko
    case Reina
    case Liz
    case Mayu
    case Ranka
    case Sheryl
    case Freyja
    case Kisaragi
    case Melon

    static let preferenceKey = "scope.densityGradient"
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .inferno:   return String(localized: "Inferno")
        case .Bochi:      return String(localized: "Hero")
        case .CRYCHIC:   return String(localized: "For life")
        case .Kumiko:      return String(localized: "Echo")
        case .Reina:  return String(localized: "Ambition")
        case .Liz:  return String(localized: "Liz")
        case .Mayu:      return String(localized: "Aqua")
        case .Ranka:       return String(localized: "Ranka")
        case .Sheryl:      return String(localized: "Sheryl")
        case .Freyja:      return String(localized: "Freyja")
        case .Kisaragi:    return String(localized: "Kisaragi")
        case .Melon:       return String(localized: "Melon")
        }
    }

    var stops: [ScopeGradientStop] {
        switch self {
        case .Mayu:
            return [
                ScopeGradientStop(   45,  43,  40, at: 0.00),
                ScopeGradientStop(   52,  89, 107, at: 0.34),
                ScopeGradientStop(  216, 251, 253, at: 0.73),
                ScopeGradientStop(  232, 232, 232, at: 1.00),
            ]
        case .inferno:
            // Matplotlib's inferno — classic "hot-body" spectrogram look.
            return [
                ScopeGradientStop(    0,    0,    0, at: 0.00),
                ScopeGradientStop(   67,   16,   92, at: 0.25),
                ScopeGradientStop(  173,   68,   82, at: 0.50),
                ScopeGradientStop(  255,  144,   57, at: 0.75),
                ScopeGradientStop(  245,  250,  167, at: 1.00),
            ]
        case .Bochi:
            return [
                ScopeGradientStop( 20, 105, 170, at: 0.00),
                ScopeGradientStop(232,  92,  82, at: 0.32),
                ScopeGradientStop(242, 173, 189, at: 0.69),
                ScopeGradientStop(241, 218, 124, at: 1.00),
            ]
        case .CRYCHIC:
            return [
                ScopeGradientStop( 74,  56,  53, at: 0.00),
                ScopeGradientStop(181, 169, 178, at: 0.24),
                ScopeGradientStop(237, 204, 142, at: 0.50),
                ScopeGradientStop(218, 227, 166, at: 0.75),
                ScopeGradientStop(203, 208, 226, at: 1.00),
            ]
        case .Kumiko:
            return [
                ScopeGradientStop( 70,  44,  38, at: 0.00),
                ScopeGradientStop(108,  30,  45, at: 0.34),
                ScopeGradientStop(217, 167,  50, at: 0.68),
                ScopeGradientStop( 84, 224, 255, at: 1.00),
            ]
        case .Reina:
            return [
                ScopeGradientStop( 46,  46,  59, at: 0.00),
                ScopeGradientStop( 77,  59, 163, at: 0.24),
                ScopeGradientStop(158, 189, 219, at: 0.54),
                ScopeGradientStop(237, 235, 255, at: 0.78),
                ScopeGradientStop(230, 195, 215, at: 1.00),
            ]
        case .Liz:
            return [
                ScopeGradientStop( 55,  63,  80, at: 0.00),
                ScopeGradientStop(  0, 123, 255, at: 0.29),
                ScopeGradientStop(163, 255, 175, at: 0.54),
                ScopeGradientStop(247, 178,  74, at: 0.77),
                ScopeGradientStop(255, 255, 255, at: 1.00),
            ]
        case .Ranka:
            return [
                ScopeGradientStop( 28,  57,  39, at: 0.00),
                ScopeGradientStop( 69, 146,  90, at: 0.25),
                ScopeGradientStop(255, 223,  82, at: 0.50),
                ScopeGradientStop(239, 116,  69, at: 0.75),
                ScopeGradientStop(156,  32,  29, at: 1.00),
            ]
        case .Sheryl:
            return [
                ScopeGradientStop( 33,  33,  33, at: 0.00),
                ScopeGradientStop( 52,  87, 187, at: 0.30),
                ScopeGradientStop( 83, 158, 224, at: 0.51),
                ScopeGradientStop(190, 148, 214, at: 0.64),
                ScopeGradientStop(255, 125, 168, at: 0.77),
                ScopeGradientStop(255, 237, 207, at: 1.00),
            ]
        case .Freyja:
            return [
                ScopeGradientStop( 15,  24,  41, at: 0.00),
                ScopeGradientStop(199,  20,  40, at: 0.33),
                ScopeGradientStop(255, 105,  20, at: 0.67),
                ScopeGradientStop(255, 229,   0, at: 1.00),
            ]
        case .Kisaragi:
            return [
                ScopeGradientStop(  0,   3,  79, at: 0.00),
                ScopeGradientStop(112, 115, 187, at: 0.33),
                ScopeGradientStop(185, 211, 234, at: 0.67),
                ScopeGradientStop(235, 242, 255, at: 1.00),
            ]
        case .Melon:
            return [
                ScopeGradientStop(   17,  51,  44, at: 0.00),
                ScopeGradientStop(   34, 203, 175, at: 0.45),
                ScopeGradientStop(   51, 240, 195, at: 0.61),
                ScopeGradientStop(  255, 241,  90, at: 1.00),
            ]
        }
    }

    /// Interpolate the colormap at a normalized intensity in [0, 1].
    /// Returns the three sRGB byte components.
    func rgb(at t: Float) -> (r: UInt8, g: UInt8, b: UInt8) {
        let clamped = max(0, min(1, t))
        let s = stops
        // Walk stops; assumes stops are sorted ascending by location.
        var i = 0
        while i + 1 < s.count && s[i + 1].location < clamped { i += 1 }
        let a = s[i]
        let b = s[min(i + 1, s.count - 1)]
        let span = max(0.0001, b.location - a.location)
        let u = (clamped - a.location) / span
        let r = Float(a.r) + (Float(b.r) - Float(a.r)) * u
        let g = Float(a.g) + (Float(b.g) - Float(a.g)) * u
        let bl = Float(a.b) + (Float(b.b) - Float(a.b)) * u
        return (UInt8(max(0, min(255, r))),
                UInt8(max(0, min(255, g))),
                UInt8(max(0, min(255, bl))))
    }

    /// SwiftUI gradient — used by the on-screen legend strip.
    var legendGradient: Gradient {
        Gradient(stops: stops.map { s in
            Gradient.Stop(
                color: Color(red: Double(s.r) / 255,
                             green: Double(s.g) / 255,
                             blue: Double(s.b) / 255),
                location: CGFloat(s.location)
            )
        })
    }
}
