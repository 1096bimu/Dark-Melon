import Foundation
@testable import Dark_Melon

@main struct PreviewHoverChecks {
    static func main() {
        let hover = PreviewHoverState()
        let toolbar = UUID(), panel = UUID()
        let pixel = CGPoint(x: 0.2, y: 0.6)
        hover.position = pixel
        precondition(hover.position == pixel)
        hover.block(toolbar, active: true)
        precondition(hover.position == nil)
        hover.position = pixel
        precondition(hover.position == nil)
        hover.block(panel, active: true)
        hover.block(toolbar, active: false)
        precondition(hover.position == nil)
        hover.block(panel, active: false)
        precondition(hover.position == nil, "Do not redisplay a stale UI-covered pixel")
        hover.position = pixel
        precondition(hover.position == pixel)
        print("PASS: UI hover suppression, overlapping surfaces, stale marker clearing and resumption")
    }
}
