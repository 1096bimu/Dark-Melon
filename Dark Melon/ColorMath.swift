import Foundation
import SwiftUI

nonisolated struct RGBColor: Equatable {
    var red: Double
    var green: Double
    var blue: Double

    static let black = RGBColor(red: 0, green: 0, blue: 0)

    var clamped: RGBColor {
        RGBColor(
            red: red.clamped(to: 0...1),
            green: green.clamped(to: 0...1),
            blue: blue.clamped(to: 0...1)
        )
    }

    var color: Color {
        Color(red: red, green: green, blue: blue)
    }

    static func mix(_ first: RGBColor, _ second: RGBColor, amount: Double) -> RGBColor {
        let amount = amount.clamped(to: 0...1)
        return RGBColor(
            red: first.red + (second.red - first.red) * amount,
            green: first.green + (second.green - first.green) * amount,
            blue: first.blue + (second.blue - first.blue) * amount
        )
    }
}


nonisolated struct HSLColor {
    var hue: Double
    var saturation: Double
    var lightness: Double

    init(hue: Double, saturation: Double, lightness: Double) {
        self.hue = hue
        self.saturation = saturation
        self.lightness = lightness
    }

    init(rgb: RGBColor) {
        let red = rgb.red
        let green = rgb.green
        let blue = rgb.blue
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let delta = maximum - minimum

        lightness = (maximum + minimum) / 2

        guard delta > 0.000_001 else {
            hue = 0
            saturation = 0
            return
        }

        saturation = delta / (1 - abs(2 * lightness - 1))

        if maximum == red {
            hue = 60 * ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
        } else if maximum == green {
            hue = 60 * (((blue - red) / delta) + 2)
        } else {
            hue = 60 * (((red - green) / delta) + 4)
        }

        hue = hue.wrappedHue
    }

    var rgb: RGBColor {
        let hue = hue.wrappedHue
        let saturation = saturation.clamped(to: 0...1)
        let lightness = lightness.clamped(to: 0...1)
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let hueSector = hue / 60
        let intermediate = chroma * (1 - abs(hueSector.truncatingRemainder(dividingBy: 2) - 1))

        let prime: RGBColor
        switch hueSector {
        case 0..<1:
            prime = RGBColor(red: chroma, green: intermediate, blue: 0)
        case 1..<2:
            prime = RGBColor(red: intermediate, green: chroma, blue: 0)
        case 2..<3:
            prime = RGBColor(red: 0, green: chroma, blue: intermediate)
        case 3..<4:
            prime = RGBColor(red: 0, green: intermediate, blue: chroma)
        case 4..<5:
            prime = RGBColor(red: intermediate, green: 0, blue: chroma)
        default:
            prime = RGBColor(red: chroma, green: 0, blue: intermediate)
        }

        let match = lightness - chroma / 2
        return RGBColor(
            red: prime.red + match,
            green: prime.green + match,
            blue: prime.blue + match
        ).clamped
    }
}

extension Double {
    nonisolated func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }

    nonisolated var wrappedHue: Double {
        let wrapped = truncatingRemainder(dividingBy: 360)
        return wrapped >= 0 ? wrapped : wrapped + 360
    }
}
