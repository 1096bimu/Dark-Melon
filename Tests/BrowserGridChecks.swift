import AppKit
import SwiftUI
import CoreImage
@testable import Dark_Melon

struct BrowserGridProbe: View {
    let model: ImageBrowserModel
    let value: Double
    var body: some View {
        ImageFileBrowser(selectedURL: nil, open: {_ in}, model:model,
                         hasPendingEdit:{_ in value > 0})
    }
}
@main struct BrowserGridChecks {
    @MainActor static func main() async throws {
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
        precondition(BrowserGridLayout.columnCount(for:BrowserGridLayout.twoColumnWidth,current:2)==2)
        for width:CGFloat in [270,271,272,273,274,275,271] {
            precondition(BrowserGridLayout.columnCount(for:width,current:2)==2,"Breakpoint jitter changed columns")
        }
        precondition(BrowserGridLayout.columnCount(for:280,current:2)==3)
        precondition(BrowserGridLayout.columnCount(for:271,current:3)==3)
        precondition(BrowserGridLayout.columnCount(for:265,current:3)==2)
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
        print("PASS: browser breakpoint hysteresis and stable loaded-thumbnail pixels through redraws at 160–271pt with long filenames; near-breakpoint resize delta=\(maximumDelta)px")
        window.close()
    }
}
