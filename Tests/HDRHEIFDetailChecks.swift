import CoreImage
@testable import Dark_Melon

@main struct HDRHEIFDetailChecks {
    static func main() async throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let space = ProcessingColorSpace.rec2020
        let context = CIContext(options: [.workingColorSpace: space.linear, .workingFormat: CIFormat.RGBAf])
        let opening = RAWDeveloper(colorSpace: space, interactive: true)
        let overview = try await opening.develop(url, progressive: true)
        assert(!overview.isRAW && overview.sourceHeadroom > 1 && !overview.fullResolutionReady)
        let decoder = RAWDeveloper(colorSpace: space, interactive: true)
        let source = try await decoder.prepareFullResolution(overview)
        assert(source.fullResolutionReady && source.id == overview.id && source.preview === overview.preview)
        let renderer = RAWDeveloper(colorSpace: space, interactive: true)
        let mapping = ToneMapping.fresh(isRAW: false, sourceHeadroom: source.sourceHeadroom)

        let referenceRenderer = RAWDeveloper(colorSpace: space)
        let referenceSampler = ScopeHoverSampler(), patchSampler = ScopeHoverSampler()
        for scale in [0.5, 1.0] {
            let scaled = source.linearSource.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let bitmap = context.createCGImage(scaled, from: scaled.extent, format: .RGBAh, colorSpace: space.linear)!
            for hdr in [false, true] {
                let reference = try await referenceRenderer.preview(bitmap, mapping: mapping, hdr: hdr)
                var worst = 0.0
                for y in [0.05, 0.4, 0.75] {
                    for x in [0.05, 0.4, 0.75] {
                        let region = PreviewRegion(rect: CGRect(x: x, y: y, width: 0.15, height: 0.15),
                            displayPixels: CGSize(width: Double(source.width) * scale, height: Double(source.height) * scale))
                        let patch = try await renderer.detail(source, mapping: mapping, hdr: hdr, region: region)
                        var energy = 0.0
                        for j in 0..<5 { for i in 0..<5 {
                            let px = floor((Double(i) + 0.5) * Double(patch.image.width) / 5)
                            let py = floor((Double(j) + 0.5) * Double(patch.image.height) / 5)
                            let local = CGPoint(x: (px + 0.5) / Double(patch.image.width),
                                                y: (py + 0.5) / Double(patch.image.height))
                            let global = CGPoint(x: patch.rect.minX + local.x * patch.rect.width,
                                                 y: patch.rect.minY + local.y * patch.rect.height)
                            let expected = try await referenceSampler.sampleRGB(reference, revision: source.id, position: global, space: space)!
                            let actual = try await patchSampler.sampleRGB(patch.image, revision: source.id, position: local, space: space)!
                            for channel in 0..<3 {
                                assert(actual[channel].isFinite)
                                worst = max(worst, abs(actual[channel] - expected[channel]))
                                energy += abs(actual[channel])
                            }
                        }}
                        assert(energy > 0, "Detail patch is black")
                    }
                }
                assert(worst < 0.025, "Detail does not match full render: \(worst)")
                print("PASS: scale \(scale), HDR \(hdr), nine patches match full render; maximum error \(worst)")
            }
        }
        print("PASS: HDR HEIF keeps overview identity and headroom while detail uses stable decoded pixels")
    }
}
