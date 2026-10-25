import CoreImage
@testable import Dark_Melon

@main struct RAWImageCacheChecks {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = CIContext()
        let image = CIImage(color: CIColor(red: 0.2, green: 0.3, blue: 0.4)).cropped(to: CGRect(x:0,y:0,width:16,height:16))
        let bitmap = context.createCGImage(image, from:image.extent, format:.RGBAh,
                                          colorSpace:ProcessingColorSpace.sRGB.linear)!
        let cache = RAWImageCache(memory: 50_000) // 10 KB: two 4 KB entries.
        func fixture(_ name: String) throws -> (RAWDevelopment, RAWImageCache.FileStamp) {
            let url = root.appendingPathComponent(name)
            try Data([1]).write(to: url)
            let development = RAWDevelopment(preview: bitmap, linearSource: CIImage(cgImage: bitmap), url:url,
                width:16,height:16,whitePoint:nil,metadata:CameraMetadata(properties:[:]),isRAW:true,
                rawDefaults:RAWSettings(),sourceHeadroom:1)
            return (development,RAWImageCache.FileStamp(url)!)
        }
        let (a,sa) = try fixture("a"), (b,sb) = try fixture("b"), (c,sc) = try fixture("c")
        func put(_ d: RAWDevelopment, _ s: RAWImageCache.FileStamp) {
            cache.insert(d,stamp:s,space:.sRGB,settings:nil,balance:nil)
        }
        func get(_ s: RAWImageCache.FileStamp) -> RAWDevelopment? {
            cache.lookup(s,space:.sRGB,settings:nil,balance:nil)
        }
        put(a,sa); put(b,sb)
        assert(get(sa)?.id == a.id) // Touch A, so B is oldest.
        put(c,sc)
        assert(get(sb) == nil && get(sa) != nil && get(sc) != nil)
        var changed = RAWSettings(); changed.values[.exposure] = 1
        assert(cache.lookup(sa,space:.sRGB,settings:changed,balance:nil) == nil)
        assert(cache.lookup(sa,space:.displayP3,settings:nil,balance:nil) == nil)
        let balance = try JSONDecoder().decode(RAWWhiteBalance.self, from:Data(#"{"temperature":5000,"tint":0}"#.utf8))
        assert(cache.lookup(sa,space:.sRGB,settings:nil,balance:balance) == nil)
        cache.rememberRange(changed, stamp:sa, space:.sRGB, settings:nil, balance:nil)
        assert(cache.range(sa,space:.sRGB,settings:nil,balance:nil) == changed)
        assert(cache.range(sa,space:.sRGB,settings:changed,balance:nil) == nil)
        var reservation: RAWImageCache.Reservation? = cache.reserve(40_000)
        assert(cache.range(sa,space:.sRGB,settings:nil,balance:nil) == nil)
        assert(get(sa) == nil && get(sc) == nil)
        withExtendedLifetime(reservation) {}
        reservation = nil
        put(a,sa); assert(get(sa) != nil)
        try Data([1,2]).write(to:a.url)
        assert(get(RAWImageCache.FileStamp(a.url)!) == nil)
        print("PASS: LRU, decode-setting/gamut/WB invalidation, file changes, export eviction and recovery")

        if CommandLine.arguments.count > 1 {
            let url = URL(fileURLWithPath: CommandLine.arguments[1])
            let worker = RAWDeveloper(colorSpace:.displayP3,interactive:true)
            let small = try await worker.develop(url,progressive:true)
            let full = try await worker.prepareFullResolution(small)
            let other = RAWDeveloper(colorSpace:.displayP3,interactive:true)
            let start = Date()
            let revisited = try await other.develop(url,progressive:true)
            assert(revisited.id == full.id && revisited.fullResolutionReady)
            assert(revisited.preview === full.preview)
            print("PASS: new browsing worker reuses full decoded RAW in",Date().timeIntervalSince(start),"seconds")
            let restored = RAWDeveloper(colorSpace:.displayP3, rawSettings:full.rawDefaults,
                rawWhiteBalance:full.whitePoint.map(RAWWhiteBalance.init), interactive:true)
            let restoredSource = try await restored.develop(url,progressive:true)
            assert(restoredSource.id == full.id)
            print("PASS: restored explicit RAW defaults and as-shot WB also reuse the cached decode")
        }
    }
}
