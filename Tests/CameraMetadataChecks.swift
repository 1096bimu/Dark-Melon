import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import Dark_Melon

@main struct CameraMetadataChecks {
    static func main() throws {
        let metadata = CameraMetadata(properties: [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2025:01:25 07:08:49",
                kCGImagePropertyExifOffsetTimeOriginal: "-04:00"],
            kCGImagePropertyDepth: 10, kCGImagePropertyColorModel: "RGB"])
        assert(metadata.captureTimeZone.secondsFromGMT() == -14400)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = metadata.captureTimeZone
        assert(calendar.component(.hour, from: metadata.captureDate!) == 7)
        assert(metadata.bitDepth == 10 && metadata.pixelFormat == "RGB" && !metadata.bitDepthIsDecoded)
        let unknown = CameraMetadata(properties: [:])
        assert(unknown.captureDate == nil && unknown.bitDepth == nil && unknown.fileSize == nil)
        let rawFallback = CameraMetadata(properties: [kCGImagePropertyDepth:16], isRAW:true)
        assert(rawFallback.bitDepthIsDecoded && rawFallback.pixelFormat == "RAW")

        func word(_ value: Int, _ width: Int) -> [UInt8] {
            (0..<width).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
        }
        func box(_ name: String, _ payload: [UInt8]) -> [UInt8] {
            word(payload.count + 8, 4) + Array(name.utf8) + payload
        }
        func codec(_ chroma: UInt8, _ depth: UInt8) -> [UInt8] {
            var data = [UInt8](repeating:0,count:19); data[0] = 1; data[16] = chroma
            data[17] = depth - 8; data[18] = depth - 8
            return box("hvcC",data)
        }
        let full = [UInt8](repeating:0,count:4)
        let definitions = box("ipco",codec(1,8) + codec(2,10))
        // Primary item 1 is a grid, whose tile 2 uses property 2. Thumbnail 3 uses property 1.
        let associations = full + word(3,4) + [0,1,0, 0,2,1,0x82, 0,3,1,0x81]
        let meta = full + box("pitm",full + word(1,2))
            + box("iref",full + box("dimg",word(1,2) + word(1,2) + word(2,2)))
            + box("iprp",definitions + box("ipma",associations))
        assert(ImageFileMetadata.heifMetadata(meta) == .init(bitDepth:10,name:"YCbCr 4:2:2"))
        for count in 0..<meta.count { _ = ImageFileMetadata.heifMetadata(Array(meta.prefix(count))) }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Data(box("ftyp",[]) + box("mdat",[UInt8](repeating:0,count:2048)) + box("meta",meta)).write(to:temporary)
        assert(ImageFileMetadata.heif(temporary) == .init(bitDepth:10,name:"YCbCr 4:2:2"))
        print("PASS: dates/time zones, unavailable metadata, decoded RAW fallback, primary/grid HEIF associations, truncation and trailing metadata")

        for path in CommandLine.arguments.dropFirst() {
            let url = URL(fileURLWithPath:path)
            let source = CGImageSourceCreateWithURL(url as CFURL,nil)!
            let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as! [CFString:Any]
            let type = UTType(CGImageSourceGetType(source)! as String)!
            let isRAW = type.conforms(to:.rawImage)
            let m = CameraMetadata(properties:properties,url:url,isRAW:isRAW,type:type)
            assert(m.fileSize! > 0 && m.captureDate != nil)
            if isRAW { assert(m.bitDepth == 14 && !m.bitDepthIsDecoded && m.pixelFormat == "RAW") }
            else { assert(m.bitDepth == 10 && m.pixelFormat == "YCbCr 4:2:2") }
            print("PASS:",url.lastPathComponent,m.bitDepth!,m.pixelFormat!,m.fileSize!,m.captureDate!.formatted(m.captureDateFormat))
        }
    }
}
