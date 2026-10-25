import CoreImage
@testable import Dark_Melon

@main struct ProgressiveRAWChecks {
    static func main() async throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let worker = RAWDeveloper(colorSpace: .displayP3, interactive: true)
        let start = Date()
        let small = try await worker.develop(url, progressive: true)
        print("Preview: \(Date().timeIntervalSince(start))s, \(small.preview.width)x\(small.preview.height), source \(small.width)x\(small.height)")
        assert(!small.fullResolutionReady)
        assert(max(small.preview.width, small.preview.height) <= 2561)
        let full = try await worker.prepareFullResolution(small)
        assert(full.fullResolutionReady && full.id == small.id)
        assert(full.preview === small.preview)
        assert(full.linearSource.extent.size == small.linearSource.extent.size)
        assert(full.linearSource.extent.width == CGFloat(full.width))
        assert(full.linearSource.extent.height == CGFloat(full.height))
        print("Full source: \(Date().timeIntervalSince(start))s")
        let detail = try await worker.detail(full, mapping: ToneMapping(), hdr: false,
            region: PreviewRegion(rect: CGRect(x: 0.4,y: 0.4,width: 0.1,height: 0.1),
                                  displayPixels: CGSize(width: full.width,height: full.height)))
        assert(detail.image.width > 0 && detail.sourceID == small.id)
        print("PASS: progressive RAW size, stable identity/overview, full-resolution extent and detail render")
    }
}
