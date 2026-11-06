import SwiftUI
import Observation
import simd
#if os(macOS)
import AppKit
#endif

@Observable final class ChromaticEdgeEditor {
    var enabled = false { didSet { redraw() } }
    var drawing = false { didSet { redraw() } }
    var line: RadialSampleLine? { didSet { redraw() } }
    var profile: ChromaticProfile?
    var draft = ChromaticAberration()
    var presenting = false { didSet { redraw() } }
    var busy = false
    var message: String?
    var geometry = DustGeometry()
    var sourceSize = CGSize(width:1,height:1)
    var transform: TransformSettings?
    var sourceID: UUID?
    var redraw: () -> Void = {}
    @ObservationIgnored private var sampling: Task<Void,Never>?
    @ObservationIgnored private var sample: ((RadialSampleLine) async throws -> ChromaticProfile)?
    @ObservationIgnored private var commit: ((ChromaticAberration) -> Void)?
    var nativeSize: CGSize { geometry.nativeSize(sourceSize) }
    func native(_ output: CGPoint) -> CGPoint { geometry.native(transform?.sourcePoint(output) ?? output) }
    func output(_ native: CGPoint) -> CGPoint {
        let p=geometry.display(native)
        guard let transform else { return p }
        let v=simd_inverse(transform.sourceHomography)*SIMD3<Double>(p.x,p.y,1)
        return CGPoint(x:v.x/v.z,y:v.y/v.z)
    }
    func start(_ development: RAWDevelopment, worker: RAWDeveloper, transform: TransformSettings?, commit: @escaping (ChromaticAberration) -> Void) {
        stop()
        sourceID=development.id;geometry=development.dustGeometry
        sourceSize=CGSize(width:development.width,height:development.height)
        self.transform=transform;draft=development.chromaticAberration;self.commit=commit
        sample={ line in
            let full = development.fullResolutionReady ? development : try await worker.prepareFullResolution(development)
            try Task.checkCancellation()
            return try await worker.chromaticProfile(full,line:line)
        }
        enabled=true;drawing=true
    }
    func finish(_ line: RadialSampleLine) {
        sampling?.cancel();self.line=line;drawing=false;profile=nil;busy=true;message=nil;presenting=true
        sampling=Task { [weak self] in
            guard let self,let sample else { return }
            do {
                let result=try await sample(line)
                try Task.checkCancellation()
                profile=result;busy=false;redraw()
            } catch is CancellationError {} catch { busy=false;message=error.localizedDescription;redraw() }
        }
    }
    func drawAgain() {
        sampling?.cancel();busy=false;profile=nil;line=nil;message=nil;drawing=true
        #if !os(macOS)
        presenting=false
        #endif
    }
    func apply() {
        guard profile != nil, draft.isValid, !busy else { return }
        let action=commit,value=draft
        stop();action?(value)
    }
    func stop() {
        sampling?.cancel();sampling=nil;sample=nil;commit=nil
        enabled=false;drawing=false;presenting=false;line=nil;profile=nil;busy=false;message=nil;sourceID=nil
    }
}

struct ChromaticEdgeInspector: View {
    @Bindable var editor: ChromaticEdgeEditor
    @State private var normalize = true
    var body: some View {
        EditorSection(title:"Chromatic Aberration") {
            Button("Close",systemImage:"xmark") { editor.stop() }.labelStyle(.iconOnly)
        } content: {
            VStack(alignment:.leading,spacing:12) {
                ChromaticEdgeGraph(profile:editor.profile,settings:editor.draft,normalize:normalize)
                    .frame(height:150)
                    .background(.black.opacity(0.3),in:.rect(cornerRadius:EditorGraphStyle.scopeCornerRadius))
                    .clipShape(.rect(cornerRadius:EditorGraphStyle.scopeCornerRadius))
                HStack {
                    Text("Red").foregroundStyle(.red)
                    Text("Green · reference").foregroundStyle(.green)
                    Text("Blue").foregroundStyle(.blue)
                    Spacer()
                    if editor.busy { ProgressView().controlSize(.small) }
                }.font(.caption)
                Toggle("Normalize Channels",isOn:$normalize)
                Text("Align the red and blue transitions with green. The graph previews your adjustments; Apply rebuilds the source.")
                    .font(.caption).foregroundStyle(.secondary)
                if editor.drawing {
                    Text("Draw across a high-contrast edge. The line follows a radius from the image center.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let message=editor.message { Text(message).font(.caption).foregroundStyle(.orange) }
                ChromaticAberrationSliders(settings:$editor.draft)
                    .disabled(editor.profile==nil || editor.busy)
                HStack {
                    Button("Draw Again") { editor.drawAgain() }
                    Spacer()
                    Button("Reset") { editor.draft=ChromaticAberration() }
                        .disabled(editor.profile==nil || editor.busy)
                    Button("Apply") { editor.apply() }
                        .disabled(editor.profile==nil || editor.busy)
                }.buttonStyle(.bordered).controlSize(.regular)
            }
        }
        .padding(EditorSectionLayout.inset)
        .modifier(ShellGlass()).environment(\.colorScheme,.dark)
        #if os(macOS)
        .frame(width:EditorSectionLayout.width)
        #endif
    }
}

struct ChromaticEdgeGraph: View {
    let profile: ChromaticProfile?
    let settings: ChromaticAberration
    let normalize: Bool
    var body: some View {
        Canvas { context,size in
            guard let profile else { return }
            let traces=(0..<3).map { profile.trace(settings,channel:$0) }
            let all=traces.flatMap { $0 }, globalLow=all.min() ?? 0, globalHigh=all.max() ?? 1
            let rect=CGRect(x:8,y:8,width:max(1,size.width-16),height:max(1,size.height-16))
            for fraction in [0.25,0.5,0.75] {
                var guide=Path();guide.move(to:CGPoint(x:rect.minX,y:rect.minY+rect.height*fraction));guide.addLine(to:CGPoint(x:rect.maxX,y:rect.minY+rect.height*fraction))
                context.stroke(guide,with:.color(.white.opacity(0.12)),lineWidth:1)
            }
            for c in [1,0,2] {
                let values=traces[c]
                let low=normalize ? values.min() ?? 0:globalLow, high=normalize ? values.max() ?? 1:globalHigh
                var path=Path()
                for (i,value) in values.enumerated() {
                    let p=CGPoint(x:rect.minX+Double(i)/Double(max(1,values.count-1))*rect.width,
                                  y:rect.maxY-(value-low)/max(1e-12,high-low)*rect.height)
                    if i==0 { path.move(to:p) } else { path.addLine(to:p) }
                }
                context.stroke(path,with:.color([Color.red,.green,.blue][c]),lineWidth:c==1 ? 2:1.5)
            }
        }
        .accessibilityLabel(Text("RGB levels along the radial sampling line"))
    }
}

#if os(macOS)
final class ChromaticEdgeOverlay: NSView {
    var editor: ChromaticEdgeEditor?
    var imageFrame = CGRect.zero
    private var inspector: NSHostingView<ChromaticEdgeInspector>?
    private var start: CGPoint?
    private var draft: RadialSampleLine?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    func refresh() {
        guard let editor,editor.enabled else { isHidden=true;inspector?.isHidden=true;return }
        isHidden=false;needsDisplay=true
        guard editor.presenting else { inspector?.isHidden=true;return }
        if inspector==nil { inspector=NSHostingView(rootView:ChromaticEdgeInspector(editor:editor));addSubview(inspector!) }
        guard let inspector else { return }
        inspector.isHidden=false
        let size=inspector.fittingSize
        let point=editor.line.map { screen($0.point(at:$0.upper)) } ?? CGPoint(x:inspector.frame.minX-35,y:inspector.frame.minY-20)
        inspector.frame=CGRect(x:min(max(8,point.x+35),max(8,bounds.width-size.width-8)),
                               y:min(max(8,point.y+20),max(8,bounds.height-size.height-8)),
                               width:size.width,height:size.height)
    }
    private func native(_ point:CGPoint) -> CGPoint {
        editor!.native(CGPoint(x:(point.x-imageFrame.minX)/imageFrame.width,y:(point.y-imageFrame.minY)/imageFrame.height))
    }
    private func screen(_ point:CGPoint) -> CGPoint {
        let p=editor!.output(point)
        return CGPoint(x:imageFrame.minX+p.x*imageFrame.width,y:imageFrame.minY+p.y*imageFrame.height)
    }
    override func hitTest(_ point:NSPoint) -> NSView? {
        guard !isHidden,editor?.enabled==true else { return nil }
        let p=convert(point,from:superview)
        if let inspector,!inspector.isHidden,inspector.frame.contains(p) { return super.hitTest(point) }
        return editor?.drawing==true && imageFrame.contains(p) ? self:nil
    }
    override func draw(_ dirtyRect:NSRect) {
        guard editor != nil,let line=draft ?? editor?.line else { return }
        let a=screen(line.point(at:line.lower)),b=screen(line.point(at:line.upper))
        let path=NSBezierPath();path.move(to:a);path.line(to:b)
        NSColor.black.setStroke();path.lineWidth=4;path.stroke()
        NSColor.white.setStroke();path.lineWidth=1.5;path.stroke()
        NSColor.white.setFill()
        for p in [a,b] { NSBezierPath(ovalIn:CGRect(x:p.x-4,y:p.y-4,width:8,height:8)).fill() }
    }
    override func mouseDown(with event:NSEvent) { start=native(convert(event.locationInWindow,from:nil));draft=nil }
    override func mouseDragged(with event:NSEvent) {
        guard let start,let editor else { return }
        draft=RadialSampleLine.constrained(from:start,to:native(convert(event.locationInWindow,from:nil)),size:editor.nativeSize)
        needsDisplay=true
    }
    override func mouseUp(with event:NSEvent) {
        mouseDragged(with:event)
        if let draft { editor?.finish(draft) }
        start=nil;draft=nil;refresh()
    }
}
#endif

#if !os(macOS)
struct ChromaticEdgeMobileOverlay: View {
    @Bindable var editor: ChromaticEdgeEditor
    let aspect: Double
    @State private var line: RadialSampleLine?
    var body: some View {
        GeometryReader { proxy in
            let frame=CropGeometry.frame(in:CGRect(origin:.zero,size:proxy.size),ratio:aspect)
            Canvas { context,_ in
                if let line=line ?? editor.line {
                    func screen(_ radius:Double) -> CGPoint {
                        let p=editor.output(line.point(at:radius))
                        return CGPoint(x:frame.minX+p.x*frame.width,y:frame.minY+p.y*frame.height)
                    }
                    var path=Path();path.move(to:screen(line.lower));path.addLine(to:screen(line.upper))
                    context.stroke(path,with:.color(.black),lineWidth:4)
                    context.stroke(path,with:.color(.white),lineWidth:1.5)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance:0).onChanged { value in
                guard editor.drawing else { return }
                func native(_ p:CGPoint) -> CGPoint { editor.native(CGPoint(x:(p.x-frame.minX)/frame.width,y:(p.y-frame.minY)/frame.height)) }
                line=RadialSampleLine.constrained(from:native(value.startLocation),to:native(value.location),size:editor.nativeSize)
            }.onEnded { _ in if let line { editor.finish(line) };line=nil })
        }
        .sheet(isPresented:$editor.presenting,onDismiss:{ if !editor.drawing { editor.stop() } }) {
            ScrollView { ChromaticEdgeInspector(editor:editor) }.presentationDetents([.large])
        }
    }
}
#endif
