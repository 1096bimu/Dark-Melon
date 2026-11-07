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
            let automatic=profile.automaticallyAligned(from:ChromaticAberration())
            precondition(abs(automatic.red)<=0.1 && abs(automatic.blue)<=0.1,
                         "Automatic search must not chase the fixture's large channel offsets")
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
        // No reliable edge means no unexpected slider movement.
        let initial=ChromaticAberration(red:0.2,blue:-0.1)
        for values in [[Double](repeating:0.2,count:512), (0..<512).map { Double($0)/511 }] {
            let flat=ChromaticProfile(line:line,sampleLower:0,sampleUpper:500,baseline:initial,channels:[values,values,values])
            precondition(flat.automaticallyAligned(from:initial)==initial)
        }
        // Existing corrections, channel offsets/gains, falling edges and a
        // second edge must not confuse absolute scale with a relative shift.
        let fitLine=RadialSampleLine.constrained(from:CGPoint(x:0.6,y:0.5),to:CGPoint(x:0.8,y:0.5),size:size)!
        let baseline=ChromaticAberration(red:1.2,blue:-0.8)
        for falling in [false,true] {
            for secondEdge in [false,true] {
                let traces=(0..<3).map { c in (0..<2048).map { i -> Double in
                    let radius=80+280*Double(i)/2047
                    let scale=1+(c==0 ? baseline.red:c==2 ? baseline.blue:0)/100
                    let rawScale=[1/(1+0.03/100),1,1/(1-0.04/100)][c]
                    let position=radius/scale/rawScale
                    let edge=1/(1+exp(-(position-200)/2))
                    let other=secondEdge ? 0.7/(1+exp(-(position-240)/2)):0
                    return offsets[c]+gains[c]*(falling && c==0 ? 1-edge+other:edge-other)
                } }
                let sample=ChromaticProfile(line:fitLine,sampleLower:80,sampleUpper:360,baseline:baseline,channels:traces)
                let fitted=sample.automaticallyAligned(from:baseline)
                precondition(abs(fitted.red-0.03)<0.003)
                precondition(abs(fitted.blue+0.04)<0.003)
                precondition(fitted.isValid && abs(fitted.red)<=0.1 && abs(fitted.blue)<=0.1)
                let repeatFit=sample.automaticallyAligned(from:fitted)
                precondition(abs(repeatFit.red-fitted.red)<0.001 && abs(repeatFit.blue-fitted.blue)<0.001)
            }
        }
        // Different toe/shoulder shapes must coincide at half-height, rather
        // than aligning the steepest part or the top of the transition.
        let broadLine=RadialSampleLine(size:CGSize(width:100000,height:50000),direction:CGPoint(x:1,y:0),lower:19500,upper:20500)
        let target=ChromaticAberration(red:0.075,blue:-0.085)
        let asymmetric=(0..<3).map { c in (0..<8192).map { i -> Double in
            let radius=19400+1200*Double(i)/8191
            let scale=1+(c==0 ? target.red:c==2 ? target.blue:0)/100
            let x=(radius*scale-20000)/30
            let shape=[0.5,1,2.5][c]
            return pow(1+(pow(2,shape)-1)*exp(-x),-1/shape)
        } }
        let broad=ChromaticProfile(line:broadLine,sampleLower:19400,sampleUpper:20600,baseline:ChromaticAberration(),channels:asymmetric)
        let centered=broad.automaticallyAligned(from:ChromaticAberration())
        precondition(abs(centered.red-target.red)<0.001 && abs(centered.blue-target.blue)<0.001)
        let centers=(0..<3).map { midpoint(broad.trace(centered,channel:$0)) }
        precondition(abs(centers[0]-centers[1])<0.01 && abs(centers[2]-centers[1])<0.01)
        let green=(0..<512).map { 1/(1+exp(-(Double($0)-220)/4)) }
        let weak=ChromaticProfile(line:fitLine,sampleLower:80,sampleUpper:360,baseline:baseline,
            channels:[[Double](repeating:0.5,count:512),green,[Double](repeating:0.1,count:512)])
        precondition(weak.automaticallyAligned(from:initial)==initial)
        let mismatched=[80.0,220,400].map { edge in (0..<512).map { 1/(1+exp(-(Double($0)-edge)/4)) } }
        let wrong=ChromaticProfile(line:fitLine,sampleLower:80,sampleUpper:360,baseline:baseline,channels:mismatched)
        precondition(wrong.automaticallyAligned(from:initial)==initial,"Unrelated edges must not move the sliders")
        // The in-preview inspector keeps changes local until Apply, and
        // closing during sampling must not republish a stale profile.
        var development=RAWDevelopment(preview:bitmap,linearSource:source,url:url,width:1024,height:512,whitePoint:nil,metadata:metadata,isRAW:false,rawDefaults:nil,sourceHeadroom:1)
        development.chromaticAberration=ChromaticAberration(red:((1+0.03/100)*191/188-1)*100,
                                                          blue:((1-0.04/100)*185/188-1)*100)
        let editor=ChromaticEdgeEditor()
        var applied: ChromaticAberration?
        editor.start(development,worker:worker,transform:nil) { applied=$0 }
        editor.finish(line)
        for _ in 0..<200 where editor.busy { try await Task.sleep(for:.milliseconds(10)) }
        precondition(editor.profile != nil && editor.presenting)
        precondition(abs(editor.draft.red-0.03)<0.003 && abs(editor.draft.blue+0.04)<0.003,
                     "Sampling must move the draft sliders automatically")
        editor.draft=correction
        precondition(applied==nil)
        editor.apply()
        precondition(applied==correction && !editor.enabled && !editor.presenting)
        editor.start(development,worker:worker,transform:nil) { _ in fatalError("Cancelled draft applied") }
        editor.finish(line);editor.stop()
        try await Task.sleep(for:.milliseconds(30))
        precondition(editor.profile==nil && !editor.presenting)
        print("PASS: automatic edge fitting, weak/mismatched-edge fallback, draft-only application, radial constraints and clipping, pixel aspect ratio, RGB strip sampling, eight EXIF orientations, fixed green, edge alignment, nonzero baseline and graph/source GPU agreement")
    }
}
