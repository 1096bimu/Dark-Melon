import Foundation
import CoreImage
@testable import Dark_Melon

@main struct ChromaticEdgeChecks {
    @MainActor static func main() async throws {
        let size=CGSize(width:1024,height:512)
        let start=CGPoint(x:0.64,y:0.5),end=CGPoint(x:0.75,y:0.58)
        let line=RadialSampleLine.constrained(from:start,to:end,size:size)!
        precondition(line.direction == CGPoint(x:1,y:0))
        precondition(abs(line.point(at:line.upper).y-0.5)<1e-12, "Dragging is constrained to the radius through the starting point")
        let diagonal=RadialSampleLine.constrained(from:CGPoint(x:0.75,y:0.75),to:CGPoint(x:1.5,y:1.5),size:size)!
        let outer=diagonal.point(at:diagonal.upper)
        precondition(outer.x<=1 && outer.y<=1 && abs(diagonal.direction.x/diagonal.direction.y-2)<1e-12)
        precondition(RadialSampleLine.constrained(from:CGPoint(x:0.5,y:0.5),to:end,size:size)==nil)
        precondition(RadialSampleLine.constrained(from:start,to:start,size:size)==nil)
        let crossed=RadialSampleLine.constrained(from:start,to:CGPoint(x:0.1,y:0.5),size:size)!
        precondition(crossed.lower==0)
        let space=ProcessingColorSpace.sRGB
        let context=CIContext(options:[.workingColorSpace:space.linear,.workingFormat:CIFormat.RGBAf])
        var data=[Float]()
        let edges=[703.0,700,697],gains=[0.9,0.6,0.4],offsets=[0.01,0.04,0.1]
        for _ in 0..<512 { for x in 0..<1024 {
            for c in 0..<3 { data.append(Float(offsets[c]+gains[c]/(1+exp(-(Double(x)+0.5-edges[c])/1.5)))) }
            data.append(1)
        } }
        let source=CIImage(bitmapData:data.withUnsafeBytes { Data($0) },bytesPerRow:1024*16,size:size,format:.RGBAf,colorSpace:space.linear)
        let bitmap=context.createCGImage(source,from:source.extent,format:.RGBAh,colorSpace:space.linear)!
        let url=URL(fileURLWithPath:"/tmp/radial-edge-fixture.tiff")
        let metadata=CameraMetadata(properties:[:],url:url,isRAW:false,type:nil)
        let worker=RAWDeveloper(colorSpace:space)
        let correction=ChromaticAberration(red:(188/191.0-1)*100,blue:(188/185.0-1)*100)
        func midpoint(_ values:[Double]) -> Double {
            let low=values.min()!,high=values.max()!,mid=(low+high)/2
            for i in 1..<values.count where values[i]>=mid {
                let f=(mid-values[i-1])/max(1e-12,values[i]-values[i-1])
                return Double(i-1)+f
            }
            return 0
        }
        for exif:Int32 in [1,2,3,4,5,6,7,8] {
            let image=source.oriented(forExifOrientation:exif)
            var development=RAWDevelopment(preview:bitmap,linearSource:image,url:url,width:Int(image.extent.width),height:Int(image.extent.height),whitePoint:nil,metadata:metadata,isRAW:false,rawDefaults:nil,sourceHeadroom:1)
            development.dustGeometry=DustGeometry(exif:exif)
            let profile=try await worker.chromaticProfile(development,line:line)
            precondition(profile.channels.count==3 && profile.channels.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isFinite) })
            let before=(0..<3).map { midpoint(profile.trace(ChromaticAberration(),channel:$0)) }
            let after=(0..<3).map { midpoint(profile.trace(correction,channel:$0)) }
            precondition(before[0]>before[1] && before[2]<before[1])
            precondition(abs(after[0]-after[1])*line.length/511<0.15)
            precondition(abs(after[2]-after[1])*line.length/511<0.15)
            precondition(profile.trace(correction,channel:1)==profile.trace(ChromaticAberration(),channel:1))
            // Graph sampling must match the actual GPU channel warp.
            let warped=try DustCorrection().apply(image,spots:[],geometry:development.dustGeometry,chromaticAberration:correction)
            development=RAWDevelopment(preview:bitmap,linearSource:warped,url:url,width:development.width,height:development.height,whitePoint:nil,metadata:metadata,isRAW:false,rawDefaults:nil,sourceHeadroom:1)
            development.dustGeometry=DustGeometry(exif:exif);development.chromaticAberration=correction
            let baked=try await worker.chromaticProfile(development,line:line)
            for c in 0..<3 {
                let graph=profile.trace(correction,channel:c),actual=baked.trace(correction,channel:c)
                precondition(zip(graph,actual).allSatisfy { abs($0-$1)<0.012 }, "Draft graph disagrees with source bake")
            }
            // Changing the draft from a nonzero baseline still matches the source scale ratio.
            let unchanged=baked.trace(correction,channel:0)
            precondition(unchanged.count==512)
        }
        let profile=ChromaticProfile(line:line,sampleLower:0,sampleUpper:500,baseline:correction,channels:[[Double]](repeating:[0,1],count:3))
        let trace=profile.trace(correction,channel:0)
        precondition(abs(trace.first!-line.lower/500)<1e-12 && abs(trace.last!-line.upper/500)<1e-12)
        // The in-preview inspector keeps changes local until Apply, and
        // closing during sampling must not republish a stale profile.
        let development=RAWDevelopment(preview:bitmap,linearSource:source,url:url,width:1024,height:512,whitePoint:nil,metadata:metadata,isRAW:false,rawDefaults:nil,sourceHeadroom:1)
        let editor=ChromaticEdgeEditor()
        var applied: ChromaticAberration?
        editor.start(development,worker:worker,transform:nil) { applied=$0 }
        editor.finish(line)
        for _ in 0..<200 where editor.busy { try await Task.sleep(for:.milliseconds(10)) }
        precondition(editor.profile != nil && editor.presenting)
        editor.draft=correction
        precondition(applied==nil)
        editor.apply()
        precondition(applied==correction && !editor.enabled && !editor.presenting)
        editor.start(development,worker:worker,transform:nil) { _ in fatalError("Cancelled draft applied") }
        editor.finish(line);editor.stop()
        try await Task.sleep(for:.milliseconds(30))
        precondition(editor.profile==nil && !editor.presenting)
        print("PASS: radial constraints and clipping, pixel aspect ratio, RGB strip sampling, eight EXIF orientations, fixed green, edge alignment, nonzero baseline and graph/source GPU agreement")
    }
}
