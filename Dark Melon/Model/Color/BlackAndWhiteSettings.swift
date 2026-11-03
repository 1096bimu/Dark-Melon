import Foundation

nonisolated struct BlackAndWhiteSettings: Codable, Equatable, Sendable {
    var isEnabled = false
    var red = 1.0
    var yellow = 1.0
    var green = 1.0
    var cyan = 1.0
    var blue = 1.0

    var isIdentity: Bool {
        !isEnabled && red == 1 && yellow == 1 && green == 1 && cyan == 1 && blue == 1
    }

    func value(at index: Int) -> Double {
        switch index {
        case 0: red
        case 1: yellow
        case 2: green
        case 3: cyan
        default: blue
        }
    }

    mutating func setValue(_ value: Double, at index: Int) {
        let value = value.clamped(to: 0...2)
        switch index {
        case 0: red = value
        case 1: yellow = value
        case 2: green = value
        case 3: cyan = value
        default: blue = value
        }
    }

    func sensitivity(at hue: Double) -> Double {
        // Magenta has no spectral control. Its hidden knot lies halfway
        // between blue and red, then the curve joins smoothly back to red.
        let position = hue.wrappedHue / 60
        let lower = Int(position)
        let amount = position - Double(lower)
        let smooth = amount * amount * (3 - 2 * amount)
        let start = spectralKnot(at: lower)
        let end = spectralKnot(at: (lower + 1) % 6)
        return start + (end - start) * smooth
    }

    private func spectralKnot(at index: Int) -> Double {
        switch index {
        case 0: red
        case 1: yellow
        case 2: green
        case 3: cyan
        case 4: blue
        default: (blue + red) / 2
        }
    }

}
