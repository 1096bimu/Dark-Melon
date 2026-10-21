import CoreGraphics
import Foundation

/// Bottom-left normalized coordinates in the final, transformed image.
nonisolated struct PreviewRegion: Equatable, Sendable {
    var rect: CGRect
    var displayPixels: CGSize
}

nonisolated struct PreviewDetail: @unchecked Sendable {
    let image: CGImage
    let rect: CGRect
    let scale: Double
    let sourceID: UUID
    let mapping: ToneMapping
    let hdr: Bool

    func covers(_ region: PreviewRegion, sourceID: UUID, mapping: ToneMapping, hdr: Bool,
                outputSize: CGSize) -> Bool {
        self.sourceID == sourceID && self.mapping == mapping && self.hdr == hdr
            && rect.contains(region.rect)
            && scale + 0.000001 >= PreviewResolution.detailScale(display: region.displayPixels, output: outputSize)
    }
}

nonisolated enum PreviewResolution {
    static func overviewScale(source: CGSize, canvas: CGSize) -> Double {
        guard source.width > 0, source.height > 0 else { return 1 }
        return min(1, max(1, canvas.width) / source.width, max(1, canvas.height) / source.height)
    }

    static func requiredScale(display: CGSize, output: CGSize) -> Double {
        min(1, max(display.width / max(1, output.width), display.height / max(1, output.height)))
    }

    static func detailScale(display: CGSize, output: CGSize) -> Double {
        let required = requiredScale(display: display, output: output)
        // Four resolution levels per octave prevent tiny zoom changes from invalidating a patch.
        return min(1, pow(2, ceil(log2(max(0.000001, required)) * 4) / 4))
    }

    static func renderRect(region: CGRect, extent: CGRect) -> CGRect {
        let visible = CGRect(x: extent.minX + region.minX * extent.width,
                             y: extent.minY + region.minY * extent.height,
                             width: region.width * extent.width, height: region.height * extent.height)
        // A small overscan lets nearby pans reuse the current patch. Blur support is
        // separate: Core Image propagates each filter's ROI upstream before this crop.
        return visible.insetBy(dx: -visible.width * 0.1, dy: -visible.height * 0.1)
            .integral.intersection(extent)
    }
}
