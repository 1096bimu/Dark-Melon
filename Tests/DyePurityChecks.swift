import Foundation
import CoreImage
@testable import Dark_Melon

@main struct DyePurityChecks {
    static func main() throws {
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let context = CIContext(options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAf])
        let film = FilmResponse()
        func render(_ rgb: [Float], _ mapping: ToneMapping) throws -> [Float] {
            let data = rgb + [0.7]
            let image = CIImage(bitmapData: data.withUnsafeBytes { Data($0) }, bytesPerRow: 16,
                size: CGSize(width: 1, height: 1), format: .RGBAf, colorSpace: space)
            var output = [Float](repeating: 0, count: 4)
            context.render(try film.apply(to: image, mapping: mapping), toBitmap: &output,
                rowBytes: 16, bounds: image.extent, format: .RGBAf, colorSpace: space)
            return output
        }
        for offsets in [[0.0,0,0], [0.2,-0.1,0.1]] {
            var original = ToneMapping()
            original.channelContrast = offsets
            var impure = original
            impure.dyePurity = [0,0.3,0.6]
            for level: Float in [0,0.0001,0.01,0.04,0.2,1,4,20] {
                let a = try render([level,level,level], original)
                let b = try render([level,level,level], impure)
                for i in 0..<4 { precondition(abs(a[i]-b[i]) < 0.0001 * max(1,abs(a[i]))) }
            }
            let a = try render([0.04,0.3,0.7], original)
            let b = try render([0.04,0.3,0.7], impure)
            precondition(zip(a,b).contains { abs($0-$1) > 0.001 })
            let exposed = [0.04, 0.3, 0.7].map { $0 / 0.7 }
            let slopes = original.dyeContrastOffsets.map { 1 + $0 }
            let h = exposed.map { log2($0 / original.tonePosition) }
            let layer = (0..<3).map { 1 / (1 + exp(-h[$0] * slopes[$0] * 0.5)) }
            let weights = [[0.0,0.08,0.03], [0.16,0,0.10], [0.06,0.20,0]]
            for c in 0..<3 {
                var delta = 0.0
                for j in 0..<3 {
                    let neutral = 1 / (1 + exp(-h[c] * slopes[j] * 0.5))
                    delta += 3 * weights[c][j] * (1 - impure.dyePurity[j]) * (neutral - layer[j])
                }
                let expected = Double(a[c]) * exp2(-8 * delta)
                precondition(abs(Double(b[c]) - expected) < 0.0001 * max(1,expected),
                             "Original 3x absorption response mismatch")
            }
            precondition(b.allSatisfy { $0.isFinite })
            precondition(abs(b[3]-0.7) < 0.0001)
            let restored = try JSONDecoder().decode(ToneMapping.self, from: JSONEncoder().encode(impure))
            precondition(restored.dyePurity == impure.dyePurity)
            precondition(SettingsPasteSelection(items: [.dyeResponse]).applying(impure, to: original).dyePurity == impure.dyePurity)
            precondition(FilmSettings(impure).applying(to: original).dyePurity == impure.dyePurity)
        }
        print("Dye purity: neutral preservation, nonlinear color change, alpha, HDR values, persistence, paste and lock passed.")
    }
}
