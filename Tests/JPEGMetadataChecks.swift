import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import Dark_Melon

@main struct JPEGMetadataChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        func segment(_ marker: UInt8, _ bytes: [UInt8]) -> [UInt8] {
            let length = bytes.count + 2
            return [0xff,marker,UInt8(length >> 8),UInt8(length & 255)] + bytes
        }
        func fixture(_ sampling: UInt8, marker: UInt8 = 0xc0, ids: [UInt8] = [1,2,3], adobe: UInt8? = nil, depth: UInt8 = 8) -> [UInt8] {
            var frame: [UInt8] = [depth,0,32,0,32,UInt8(ids.count)]
            for (index,id) in ids.enumerated() { frame += [id,index == 0 ? sampling : 0x11,0] }
            // Include a fake embedded JPEG thumbnail: it must not determine base-image sampling.
            let exif = segment(0xe1,[0xff,0xd8] + segment(0xc0,[8,0,1,0,1,3,1,0x22,0,2,0x11,0,3,0x11,0]))
            var bytes = [UInt8]([0xff,0xd8]) + exif + segment(marker,frame)
            // Adobe APP14 can follow SOF, so the parser must continue up to SOS.
            if let adobe { bytes += segment(0xee,Array("Adobe".utf8) + [0,100,0,0,0,0,adobe]) }
            return bytes + [0xff,0xda,0,2,0xff,0xd9]
        }
        let cases: [(UInt8,String)] = [(0x22,"4:2:0"),(0x21,"4:2:2"),(0x11,"4:4:4"),(0x12,"4:4:0"),(0x41,"4:1:1")]
        let file = root.appendingPathComponent("test.jpg")
        for marker: UInt8 in [0xc0,0xc2] {
            for (sampling,name) in cases {
                try Data(fixture(sampling,marker:marker)).write(to:file)
                assert(ImageFileMetadata.jpeg(file) == .init(bitDepth:8,name:"YCbCr " + name))
            }
        }
        for (ids,adobe,name) in [([UInt8]("RGB".utf8),nil,"RGB"),([1,2,3],UInt8(0),"RGB"),([1],nil,String(localized:"Monochrome")),([1,2,3,4],nil,"CMYK"),([1,2,3,4],UInt8(2),"YCCK")] {
            try Data(fixture(0x11,ids:ids,adobe:adobe)).write(to:file)
            assert(ImageFileMetadata.jpeg(file)?.name == name)
        }
        try Data(fixture(0x22,depth:12)).write(to:file)
        assert(ImageFileMetadata.jpeg(file)?.bitDepth == 12)
        try Data(fixture(0x20)).write(to:file)
        assert(ImageFileMetadata.jpeg(file) == nil)
        let base = fixture(0x21)
        for count in 0..<base.count {
            try Data(base.prefix(count)).write(to:file)
            _ = ImageFileMetadata.jpeg(file)
        }
        try Data(base + fixture(0x22)).write(to:file)
        assert(ImageFileMetadata.jpeg(file)?.name == "YCbCr 4:2:2")
        print("PASS: baseline/progressive sampling, RGB/Adobe/monochrome/CMYK, 12-bit precision, malformed data, embedded thumbnails and appended gain maps")
        for path in CommandLine.arguments.dropFirst() {
            let url = URL(fileURLWithPath:path)
            let source = CGImageSourceCreateWithURL(url as CFURL,nil)!
            let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as! [CFString:Any]
            let result = CameraMetadata(properties:properties,url:url,type:.jpeg)
            assert(result.pixelFormat?.contains("YCbCr") == true || result.pixelFormat == "RGB")
            assert(result.bitDepth != nil)
            print("PASS:",url.lastPathComponent,result.bitDepth!,result.pixelFormat!)
        }
    }
}
