import AppKit
import ImageIO
import SwiftUI
@testable import Dark_Melon

@main struct PreviewInfoPillChecks {
    @MainActor static func main() {
        let metadata = CameraMetadata(properties: [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "Canon"],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifFNumber: 4.0,
                kCGImagePropertyExifExposureTime: 1.0 / 60,
                kCGImagePropertyExifFocalLength: 35.0,
                kCGImagePropertyExifDateTimeOriginal: "2026:07:12 05:13:00",
                kCGImagePropertyExifOffsetTimeOriginal: "+03:00"
            ]
        ])
        let url = URL(fileURLWithPath: "/212A8723.CR3")
        func info(_ fields: Int) -> PreviewInfoContent {
            PreviewInfoContent(current: url, resolution: CGSize(width: 8192, height: 5464), fileSize: 58_000_000,
                metadata: metadata, position: "17 / 42", fields: fields)
        }
        let original = info(InfoPillField.standard)
        precondition(original.name == "212A8723")
        precondition(original.facts.map(\.field) == [.fileSize, .dimensions, .format])
        precondition(original.facts[1].text == "8192 × 5464  44.8 MP")
        precondition(original.facts.last?.text == "CR3")
        precondition(original.details!.contains("Canon  ·  f/4.0  ·  1/60s  ·  35mm"))
        precondition(original.details!.contains("5:13"), "Capture time shifted away from the camera's wall-clock time")

        let withoutDimensions = info(InfoPillField.dimensions.settingVisible(false, in: InfoPillField.standard))
        precondition(withoutDimensions.facts.filter { $0.field == .megapixels }.map(\.text) == ["44.8 MP"])
        let withoutMegapixels = info(InfoPillField.megapixels.settingVisible(false, in: InfoPillField.standard))
        precondition(withoutMegapixels.facts.first { $0.field == .dimensions }?.text == "8192 × 5464")
        precondition(info(0).isEmpty)
        let positioned = info(InfoPillField.position.settingVisible(true, in: InfoPillField.standard))
        precondition(positioned.facts.first?.text == "17 / 42")

        let unknownField = 1 << 12
        for field in InfoPillField.allCases {
            let fields = InfoPillField.standard | unknownField
            let toggled = field.settingVisible(!field.isVisible(in: fields), in: fields)
            precondition((fields ^ toggled) == field.rawValue, "Toggling one item changed other preferences")
            precondition(toggled & unknownField != 0)
        }
        let noMetadata = PreviewInfoContent(current: url, resolution: .zero, fileSize: nil,
            metadata: nil, position: nil, fields: InfoPillField.standard)
        precondition(noMetadata.name == "212A8723" && noMetadata.details == nil)
        precondition(noMetadata.facts.map(\.field) == [.format])
        print("PASS: three-row metadata, grouped dimensions/MP, individual visibility, empty state, and missing EXIF")
    }
}
