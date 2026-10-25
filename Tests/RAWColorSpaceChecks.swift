import CoreImage
@testable import Dark_Melon

@main struct RAWColorSpaceChecks {
    @MainActor static func main() async throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        var settings = RAWSettings(); settings.useRAW9 = true
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let context = CIContext(options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAf])
        var reference: [Float]?
        for gamut in ProcessingColorSpace.allCases {
            let worker = RAWDeveloper(colorSpace: gamut, rawSettings: settings, interactive: true)
            let development = try await worker.develop(url, progressive: true)
            let image = CIImage(cgImage: development.preview)
            let small = image.transformed(by: CGAffineTransform(scaleX: 64 / image.extent.width, y: 64 / image.extent.height))
            var pixels = [Float](repeating: 0, count: 64 * 64 * 4)
            context.render(small, toBitmap: &pixels, rowBytes: 64 * 16,
                           bounds: CGRect(x: 0, y: 0, width: 64, height: 64), format: .RGBAf, colorSpace: space)
            if let reference {
                let error = zip(reference, pixels).map { abs($0 - $1) }.max()!
                print(gamut, "maximum common-space error", error)
                assert(error < 0.003, "RAW decode depends on editing gamut")
            } else { reference = pixels }
        }
        print("PASS: RAW 9 source colors agree across all editing gamuts")
    }
}
