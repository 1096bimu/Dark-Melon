import Foundation
import CoreImage
@testable import Dark_Melon
@main struct ShadowFloorChecks {
    static func main() throws {
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let context = CIContext(options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAf])
        let kernel = MetalImageKernels.color("shadowFloor")!
        for rgb: [Float] in [[0,0,0], [0.01,0.02,0.03], [0.01,0.2,0.03], [0.2,0.3,0.4], [2,3,4]] {
            let input = rgb + [1]
            let image = CIImage(bitmapData: input.withUnsafeBytes { Data($0) }, bytesPerRow: 16,
                size: CGSize(width: 1,height: 1),format: .RGBAf,colorSpace: space)
            let result = kernel.apply(extent: image.extent, arguments: [image, 0.1])!
            var pixel = [Float](repeating: 0,count: 4)
            context.render(result,toBitmap:&pixel,rowBytes:16,bounds:image.extent,format:.RGBAf,colorSpace:space)
            for c in 0..<3 {
                let expected = max(0.1, Double(rgb[c]))
                precondition(abs(Double(pixel[c])-expected)<0.00001)
            }
            precondition(pixel[3] == 1)
        }
        var mapping = ToneMapping()
        mapping.shadowFloor = 0.04
        let restored = try JSONDecoder().decode(ToneMapping.self,from:JSONEncoder().encode(mapping))
        precondition(restored.shadowFloor == 0.04)
        precondition(SettingsPasteSelection(items:[.shadowFloor]).applying(mapping,to:ToneMapping()).shadowFloor == 0.04)
        print("Shadow floor: shared RGB clipping, mixed-channel shadows, black, HDR, alpha, persistence and paste passed.")
    }
}
