import AppKit
import SwiftUI
import CoreImage
@testable import Dark_Melon

struct BrowserGridProbe: View {
    let model: ImageBrowserModel
    let value: Double
    var body: some View {
        ImageFileBrowser(selectedURL: nil, open: {_ in}, model:model,
                         pendingURLs: value > 0 ? Set(model.entries.prefix(1).map(\.url)) : [])
    }
}
@main struct BrowserGridChecks {
    @MainActor static func main() async throws {
        let zoomKey = "browser.thumbnailColumnAdjustment"
        let previousZoom = UserDefaults.standard.object(forKey: zoomKey)
        UserDefaults.standard.set(0, forKey: zoomKey)
        defer {
            if let previousZoom { UserDefaults.standard.set(previousZoom, forKey: zoomKey) }
            else { UserDefaults.standard.removeObject(forKey: zoomKey) }
        }
        let app=NSApplication.shared
        app.setActivationPolicy(.accessory)
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let context=CIContext()
        let model=ImageBrowserModel();model.root=folder;model.directory=folder
        for i in 0..<12 {
            let file=folder.appendingPathComponent("photo-\(i)-a-long-camera-filename-Enhanced-NR.png")
            let image=CIImage(color:CIColor(red:0.2,green:0.5,blue:0.8)).cropped(to:CGRect(x:0,y:0,width:i.isMultiple(of:2) ? 32:24,height:i.isMultiple(of:2) ? 24:32))
            try context.writePNGRepresentation(of:image,to:file,format:.RGBA8,colorSpace:ProcessingColorSpace.sRGB.encoded)
            model.entries.append(BrowserEntry(url:file,isFolder:false))
        }
        let host=NSHostingView(rootView:BrowserGridProbe(model:model,value:0))
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:271,height:600),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.contentView=host;window.makeKeyAndOrderFront(nil)
        func capture() -> NSBitmapImageRep {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds)!
            host.cacheDisplay(in:host.bounds,to:bitmap)
            return bitmap
        }
        func mask(_ bitmap:NSBitmapImageRep) -> [Bool] {
            var values:[Bool]=[]
            for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
                let c=bitmap.colorAt(x:x,y:y)!.usingColorSpace(.sRGB)!
                values.append(c.blueComponent > c.greenComponent + 0.08 && c.greenComponent > c.redComponent + 0.08)
            }}
            return values
        }
        func widestRun(_ values:[Bool], width:Int) -> Int {
            var maximum=0,run=0
            for i in values.indices {
                if i.isMultiple(of:width) || !values[i] { run=0 }
                if values[i] { run += 1; maximum=max(maximum,run) }
            }
            return maximum
        }
        for width: CGFloat in [160, 180, 271, 364, 800, 1200] {
            for expanded in [false, true] {
                for adjustment in -5...12 {
                    let columns = BrowserGridLayout.columnCount(for: width, expanded: expanded, adjustment: adjustment)
                    let cell = BrowserGridLayout.cellWidth(for: width, columns: columns)
                    let occupied = CGFloat(columns) * cell + CGFloat(columns - 1) * BrowserGridLayout.spacing + 2 * BrowserGridLayout.padding
                    precondition(abs(occupied - width) < 0.001, "Grid leaves unused width or overflows")
                    precondition(cell >= 64, "Thumbnail shrunk below its usable minimum")
                }
            }
        }
        try await Task.sleep(for:.milliseconds(400))
        for width:CGFloat in [160,175,179,180,181,183,184,185,188,200,240,271] {
            window.setContentSize(NSSize(width:width,height:600))
            try await Task.sleep(for:.milliseconds(150))
            let baseline=mask(capture())
            precondition(baseline.filter{$0}.count > 5000,"Thumbnail fixture did not render")
            for i in 1...8 {
                host.rootView=BrowserGridProbe(model:model,value:i.isMultiple(of:2) ? 0:1)
                try await Task.sleep(for:.milliseconds(20))
                precondition(mask(capture()) == baseline,"Thumbnail size changed during editor redraw")
            }
        }
        let initial=capture()
        let initialRun=widestRun(mask(initial),width:initial.pixelsWide)
        var maximumDelta=0
        for width:CGFloat in [272,271,273,271,272,271] {
            window.setContentSize(NSSize(width:width,height:600))
            host.rootView=BrowserGridProbe(model:model,value:Double(width))
            try await Task.sleep(for:.milliseconds(80))
            let bitmap=capture()
            let delta=abs(widestRun(mask(bitmap),width:bitmap.pixelsWide)-initialRun)
            maximumDelta=max(maximumDelta,delta)
            precondition(delta <= 4,"Tiny viewport change caused a large thumbnail zoom")
        }
        for (adjustment, larger) in [(-1, true), (1, false)] {
            UserDefaults.standard.set(adjustment, forKey: zoomKey)
            try await Task.sleep(for: .milliseconds(150))
            let bitmap = capture()
            let run = widestRun(mask(bitmap), width: bitmap.pixelsWide)
            precondition(larger ? run > initialRun : run < initialRun, "Thumbnail size control did not resize loaded images")
        }
        print("PASS: grids fill available width; thumbnail zoom works; loaded images stay stable through editor redraws; resize delta=\(maximumDelta)px")
        window.close()
    }
}
