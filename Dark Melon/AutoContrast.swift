import CoreGraphics
import Foundation

nonisolated enum AutoContrast {
    static func suggestion(median: Int, mapping: ToneMapping, space: ProcessingColorSpace) -> Double? {
        guard mapping.tonePosition == 0, mapping.concentration >= 0,
              median > 130 else { return nil }
        // Aim one code value inside the acceptable interval to allow rounding.
        let target = 129
        func linear(_ code: Int) -> Double? {
            let v = Double(code) / 255
            guard let color = CGColor(colorSpace: space.encoded, components: [v,v,v,1]),
                  let values = color.converted(to: space.linear, intent: .relativeColorimetric, options: nil)?.components else { return nil }
            return Double(values[0])
        }
        guard let current = linear(median), let desired = linear(target),
              current > 0, current < 1, desired > 0, desired < 1 else { return nil }
        let power = pow(257, mapping.concentration)
        let logRemainingInput = log1p(-current) / power
        let nextPower = log1p(-desired) / logRemainingInput
        if nextPower >= 1 { return min(1, log(nextPower) / log(257)) }
        // Tone-zero negative Contrast uses the normalized integral of
        // 1 - q(1-x)^2. Solve for q instead of extending the positive formula.
        let x = -expm1(logRemainingInput)
        let integral = x - x*x + x*x*x/3
        let denominator = integral - desired/3
        guard denominator > 0 else { return -1 }
        return -min(1, max(0, (x-desired)/denominator))
    }
}
