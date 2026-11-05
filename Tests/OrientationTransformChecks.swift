import AppKit
import CoreImage
import SwiftUI
import Observation
import QuartzCore
@testable import Dark_Melon

@MainActor @Observable private final class OrientationLayoutState {
    var image: CGImage
    var height: CGFloat = 0
    init(_ image: CGImage) { self.image = image }
}
private struct OrientationLayoutRoot: View {
    let state: OrientationLayoutState
    var body: some View {
        ScrollView {
            TransformControls(cropping: false, orientation: .constant(SourceOrientation()), orientationChanged: {},
                image: state.image, polygon: [CGPoint(x:0,y:0), CGPoint(x:1,y:0), CGPoint(x:1,y:1), CGPoint(x:0,y:1)],
                resolution: CGSize(width:3000,height:2000), maximumResolution: CGSize(width:3000,height:2000),
                toggle: {}, resetPerspective: {}, resetRotation: {}, resetAll: {})
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { state.height = $0 }
        }.frame(width: 380)
    }
}

@main struct OrientationTransformChecks {
    @MainActor static func main() async throws {
        let orientations = (0..<4).flatMap { turn in [false,true].map { SourceOrientation(quarterTurns:turn, mirrored:$0) } }
        let bounds = CGRect(x:0,y:0,width:800,height:600)
        let transform = CropTransform(rotation:0.12, horizontal:0.05, vertical:-0.03)
        let originalCrop = CropGeometry.frame(in:bounds,ratio:1.5)
        let polygon = transform.sourcePolygon(crop:originalCrop, bounds:bounds, imageSize:CGSize(width:1800,height:1200),
            center:CGPoint(x:400,y:300), pan:CGPoint(x:20,y:-10), flippedY:true)
        let original = TransformSettings(points:polygon, ratioPosition:8, rotation:transform.rotation, horizontal:transform.horizontal, vertical:transform.vertical)
        precondition(original.isValid)
        let epsilon = 1e-15
        let full = TransformSettings(points:[CGPoint(x:epsilon,y:epsilon),CGPoint(x:1-epsilon,y:epsilon),CGPoint(x:1-epsilon,y:1-epsilon),CGPoint(x:epsilon,y:1-epsilon)],
            ratioPosition:8,rotation:0,horizontal:0,vertical:0)
        for orientation in orientations {
            let swapped = !orientation.turns.isMultiple(of:2)
            let width = swapped ? 400 : 600, height = swapped ? 600 : 400
            let rotated = full.reoriented(from:SourceOrientation(),to:orientation)
            precondition(rotated.resolution(width:width,height:height,estimate:.maximum) == CGSize(width:width,height:height))
        }
        for old in orientations { for new in orientations {
            let result = original.reoriented(from:old,to:new)
            precondition(result.isValid)
            let swapped = (old.turns - new.turns).isMultiple(of:2) == false
            precondition(abs(result.aspect - (swapped ? 1/original.aspect : original.aspect)) < 1e-10)
            let restored = result.reoriented(from:new,to:old)
            precondition(abs(restored.aspect-original.aspect)<1e-10)
            precondition(abs(restored.rotation-original.rotation)<1e-10 && abs(restored.horizontal-original.horizontal)<1e-10 && abs(restored.vertical-original.vertical)<1e-10)
            for (a,b) in zip(restored.points, original.points) { precondition(hypot(a.x-b.x,a.y-b.y)<1e-10) }
            for q in [CGPoint(x:0.2,y:0.3), CGPoint(x:0.5,y:0.5), CGPoint(x:0.8,y:0.7)] {
                let oldOutput = old.apply(to:new.sourcePoint(q))
                let expected = new.apply(to:old.sourcePoint(original.sourcePoint(oldOutput)))
                let actual = result.sourcePoint(q)
                precondition(hypot(actual.x-expected.x,actual.y-expected.y)<1e-9, "Crop sampled different pixels after reorientation")
            }
        }}
        // Perspective controls must reconstruct the rotated saved crop when editing resumes.
        for new in orientations {
            let saved = original.reoriented(from:SourceOrientation(),to:new)
            let controls = CropTransform(rotation:saved.rotation,horizontal:saved.horizontal,vertical:saved.vertical)
            let frame = CropGeometry.frame(in:bounds,ratio:saved.aspect)
            let fitted = new.turns.isMultiple(of:2) ? CGSize(width:800,height:800/1.5) : CGSize(width:400,height:600)
            let restored = controls.restoredViewport(saved,crop:frame,bounds:bounds,fittedSize:fitted,flippedY:true)
            let size = CGSize(width:fitted.width*restored.zoom,height:fitted.height*restored.zoom)
            let actual = controls.sourcePolygon(crop:frame,bounds:bounds,imageSize:size,center:CGPoint(x:400,y:300),pan:restored.pan,flippedY:true)
            for (a,b) in zip(actual,saved.points) { precondition(hypot(a.x-b.x,a.y-b.y)<1e-8, "Perspective controls no longer match the saved crop") }
        }
        var panorama = original; panorama.ratioPosition = 11
        let portrait = panorama.reoriented(from:SourceOrientation(),to:SourceOrientation(quarterTurns:1))
        precondition(abs(portrait.aspect-24.0/65)<1e-10 && portrait.isValid)
        let recipe = DevelopmentRecipe(colorSpace:.sRGB,mapping:{ var m=ToneMapping(); m.transform=portrait; return m }())
        let roundTrip = try DevelopmentRecipe.decode(recipe.encoded())
        precondition(roundTrip.mapping.transform == portrait)
        for i in -100...1100 {
            let p=Double(i)/100
            precondition(abs(CropGeometry.position(for:CropGeometry.ratio(at:p))-p)<1e-9)
        }

        _ = NSApplication.shared
        let context=CIContext()
        let raster = CIFilter(name:"CILinearGradient",parameters:[
            "inputPoint0": CIVector(x:0,y:0), "inputPoint1": CIVector(x:120,y:80),
            "inputColor0": CIColor(red:0.1,green:0.2,blue:0.3), "inputColor1": CIColor(red:0.9,green:0.7,blue:0.5)
        ])!.outputImage!.cropped(to:CGRect(x:0,y:0,width:120,height:80))
        func pixel(_ image:CIImage,_ p:CGPoint) -> [Float] {
            var values=[Float](repeating:0,count:4)
            context.render(image,toBitmap:&values,rowBytes:16,
                bounds:CGRect(x:floor(p.x*image.extent.width),y:floor((1-p.y)*image.extent.height),width:1,height:1),
                format:.RGBAf,colorSpace:ProcessingColorSpace.sRGB.linear)
            return values
        }
        for orientation in orientations {
            for point in [CGPoint(x:10.5/120,y:20.5/80),CGPoint(x:90.5/120,y:60.5/80)] {
                let expected=pixel(raster,point)
                let actual=pixel(orientation.apply(to:raster),orientation.apply(to:point))
                precondition(zip(expected,actual).allSatisfy { abs($0-$1)<0.001 },"Crop coordinate orientation disagrees with image pixels")
            }
        }
        func bitmap(_ width:Int,_ height:Int) -> CGImage {
            let image=CIImage(color:CIColor(red:0.3,green:0.2,blue:0.1)).cropped(to:CGRect(x:0,y:0,width:width,height:height))
            return context.createCGImage(image,from:image.extent)!
        }
        let landscape=bitmap(300,200), upright=bitmap(200,300)
        let state=OrientationLayoutState(landscape)
        let window=NSWindow(contentRect:CGRect(x:100,y:100,width:380,height:600),styleMask:[.borderless],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false
        window.contentView=NSHostingView(rootView:OrientationLayoutRoot(state:state))
        window.orderFront(nil)
        try await Task.sleep(for:.milliseconds(150))
        let height=state.height
        precondition(height>0)
        for image in [upright,landscape,upright,landscape] {
            state.image=image
            try await Task.sleep(for:.milliseconds(30))
            precondition(abs(state.height-height)<0.01,"Orientation resized the control panel")
        }
        let display=HDRImagePreview.ImageDisplay(viewport:PreviewViewport())
        window.contentView=display
        let sourceID=UUID()
        func show(_ image:CGImage,_ size:CGSize) {
            display.display(image,sdrImage:image,surface:nil,sdrSurface:nil,sourceSize:size,detail:nil,hdr:false,sourceID:sourceID,screenSaverActive:false)
        }
        func imageBounds() -> CGRect { display.layer!.sublayers!.compactMap { $0 as? CAMetalLayer }.last!.bounds }
        show(landscape,CGSize(width:3000,height:2000))
        for _ in 0..<100 {
            if imageBounds().width>0 { break }
            try await Task.sleep(for:.milliseconds(10))
        }
        precondition(imageBounds().width>0)
        let old=imageBounds()
        show(landscape,CGSize(width:2000,height:3000))
        try await Task.sleep(for:.milliseconds(30))
        precondition(imageBounds()==old,"New metadata stretched the old frame")
        show(upright,CGSize(width:2000,height:3000))
        for _ in 0..<100 {
            if abs(imageBounds().width/imageBounds().height-2.0/3)<0.0001 { break }
            try await Task.sleep(for:.milliseconds(10))
        }
        precondition(abs(imageBounds().width/imageBounds().height-2.0/3)<0.0001)
        window.close()
        print("PASS: all 64 orientation transitions, crop/aspect/homography preservation, mirror/perspective restoration, panoramic aspect/recipe compatibility, stable panel height and frame/geometry synchronization")
    }
}
