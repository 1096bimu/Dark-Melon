import SwiftUI
import Observation
import simd

@Observable final class DustEditor {
    var redraw: () -> Void = {}
    var enabled = false { didSet { redraw() } }
    var adding = false
    var selected: UUID? { didSet { redraw() } }
    var spots: [DustSpot] = []
    var geometry = DustGeometry()
    var sourceSize = CGSize(width: 1,height: 1)
    var transform: TransformSettings?
    var profile: DustProfile?
    var busy = false
    var message: String?
    var change: ([DustSpot]) -> Void = { _ in }
    var fit: (DustSpot) -> Void = { _ in }
    var resample: (DustSpot) -> Void = { _ in }
    var selectedSpot: DustSpot? { spots.first { $0.id == selected } }
    var nativeSize: CGSize { geometry.nativeSize(sourceSize) }
    func update(_ spot: DustSpot) {
        guard spot.isValid, let i=spots.firstIndex(where:{$0.id==spot.id}) else { return }
        spots[i]=spot; change(spots); redraw()
    }
    func remove() {
        spots.removeAll{$0.id==selected}; selected=nil; profile=nil; change(spots)
    }
    func native(_ output: CGPoint) -> CGPoint {
        let p=transform?.sourcePoint(output) ?? output
        return geometry.native(p)
    }
    func output(_ native: CGPoint) -> CGPoint {
        let p=geometry.display(native)
        guard let transform else { return p }
        let v=simd_inverse(transform.sourceHomography)*SIMD3<Double>(p.x,p.y,1)
        return CGPoint(x:v.x/v.z,y:v.y/v.z)
    }
    func offset(_ spot: DustSpot, distance: Double, angle: Double) -> CGPoint {
        let size=nativeSize, edge=min(size.width,size.height)
        return CGPoint(x:spot.center.x+cos(angle)*distance*edge/size.width,
                       y:spot.center.y+sin(angle)*distance*edge/size.height)
    }
    func create(_ start: CGPoint, _ end: CGPoint) {
        let size=nativeSize, short=min(size.width,size.height)
        let dx=(end.x-start.x)*size.width, dy=(end.y-start.y)*size.height
        let length=hypot(dx,dy)/short
        guard length>0.0001, spots.count<128 else { return }
        var spot=DustSpot(center:CGPoint(x:(start.x+end.x)/2,y:(start.y+end.y)/2))
        spot.angle=atan2(dy,dx);spot.length=length;spot.radius=length*0.1;spot.feather=length*0.15
        guard spot.isValid else { return }
        spots.append(spot);selected=spot.id;adding=false;fit(spot)
    }
}

struct DustControls: View {
    @Bindable var editor: DustEditor
    @Binding var spots: [DustSpot]?
    let activate: () -> Void
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Dust Correction").font(.headline)
            HStack {
                Button(editor.enabled ? "Done" : "Add Spot",systemImage:"circle.dotted") {
                    if editor.enabled { editor.enabled=false;editor.adding=false }
                    else { activate();editor.enabled=true;editor.adding=true }
                }
                if editor.enabled {
                    Button("Add Spot") { editor.adding=true;editor.selected=nil;editor.profile=nil }
                }
                Spacer()
                Button("Clear Spots") { spots=nil;editor.spots=[];editor.selected=nil;editor.profile=nil }
                    .disabled((spots ?? []).isEmpty)
            }.buttonStyle(.bordered)
            if editor.enabled {
                Text("Draw through the center of the dust, extending both ends into clean background.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array((spots ?? []).enumerated()),id:\.element.id) { i,spot in
                Button {
                    activate();editor.enabled=true;editor.adding=false;editor.selected=spot.id;editor.resample(spot)
                } label: {
                    HStack { Image(systemName:"circle.dotted"); Text("Spot \(i+1)"); Spacer(); if editor.selected==spot.id { Image(systemName:"checkmark") } }
                }.buttonStyle(.plain)
            }
        }.padding(16).modifier(ShellSection())
    }
}

struct DustInspector: View {
    @Bindable var editor: DustEditor
    private func value(_ key: WritableKeyPath<DustSpot,Double>, scale: Double = 1) -> Binding<Double> {
        Binding(get: { (editor.selectedSpot?[keyPath:key] ?? 0)*scale }, set: {
            guard var spot=editor.selectedSpot else { return }
            spot[keyPath:key]=$0/scale;editor.update(spot)
        })
    }
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            HStack { Text("Dust Correction").font(.headline); Spacer(); Button { editor.selected=nil } label: { Image(systemName:"xmark") }.buttonStyle(.plain) }
            if let spot=editor.selectedSpot {
                DustProfileGraph(profile:editor.profile,spot:spot).frame(height:90)
                HStack { Text("Source").foregroundStyle(.secondary); Text("Corrected").foregroundStyle(.cyan); Text("Background").foregroundStyle(.orange) }.font(.caption2)
                row("Angle",value(\.angle,scale:180 / .pi))
                row("Line Length",value(\.length,scale:100))
                row("Radius",value(\.radius,scale:100))
                row("Falloff",value(\.feather,scale:100))
                row("Attenuation",value(\.attenuation,scale:100))
                HStack {
                    Text("Center")
                    AdjustmentField(title:"X",value: Binding(get:{spot.center.x},set:{var s=spot;s.center.x=$0;editor.update(s)}),range:0...1,digits:3,scale:100,width:75,commit:{ if let s=editor.selectedSpot { editor.resample(s) } })
                    AdjustmentField(title:"Y",value: Binding(get:{spot.center.y},set:{var s=spot;s.center.y=$0;editor.update(s)}),range:0...1,digits:3,scale:100,width:75,commit:{ if let s=editor.selectedSpot { editor.resample(s) } })
                }.textFieldStyle(.roundedBorder)
                Text("Distances and coordinates are percentages of the native image; distances use its shorter edge.").font(.caption2).foregroundStyle(.secondary)
                HStack {
                    Button("Refit") { editor.fit(spot) }.disabled(editor.busy)
                    Button("Delete",role:.destructive) { editor.remove() }
                    if editor.busy { ProgressView().controlSize(.small) }
                }.buttonStyle(.bordered)
            }
            if let message=editor.message { Text(message).font(.caption).foregroundStyle(.orange) }
        }.padding(12).frame(width:280).background(.regularMaterial,in:RoundedRectangle(cornerRadius:12))
    }
    private func row(_ title: LocalizedStringKey,_ binding: Binding<Double>) -> some View {
        HStack { Text(title);Spacer();AdjustmentField(title:title,value:binding,range:-100000...100000,digits:3,width:85,commit:{ if let spot=editor.selectedSpot { editor.resample(spot) } }) }
    }
}

private struct DustProfileGraph: View {
    let profile: DustProfile?
    let spot: DustSpot
    var body: some View {
        Canvas { context,size in
            guard let profile,!profile.values.isEmpty else { return }
            let original=profile.values
            let corrected=original.enumerated().map { i,y in y/spot.transmission(abs((Double(i)/Double(original.count-1)-0.5)*spot.length)) }
            let all=original+corrected+profile.background
            let low=all.min() ?? 0, high=all.max() ?? 1, span=max(1e-9,high-low)
            for (values,color) in [(original,Color.gray),(profile.background,Color.orange),(corrected,Color.cyan)] {
                var path=Path()
                for (i,y) in values.enumerated() {
                    let p=CGPoint(x:Double(i)/Double(max(1,values.count-1))*size.width,y:(1-(y-low)/span)*size.height)
                    if i==0 { path.move(to:p) } else { path.addLine(to:p) }
                }
                context.stroke(path,with:.color(color),lineWidth:1.5)
            }
        }.background(.black.opacity(0.35))
    }
}

#if os(macOS)
import AppKit
/// Lives above image layers; empty space passes through for ordinary mouse/trackpad navigation.
final class DustOverlay: NSView {
    var editor: DustEditor?
    var imageFrame = CGRect.zero
    private var inspector: NSHostingView<DustInspector>?
    private var drag: (DustSpot, Int, CGPoint)?
    private var start: CGPoint?
    private var end: CGPoint?
    override var isFlipped: Bool { true }
    func refresh() {
        guard let editor,editor.enabled else { isHidden=true;inspector?.isHidden=true;return }
        isHidden=false;needsDisplay=true
        if let spot=editor.selectedSpot {
            if inspector==nil { inspector=NSHostingView(rootView:DustInspector(editor:editor));addSubview(inspector!) }
            inspector?.isHidden=false
            let p=screen(spot.center)
            inspector?.frame=CGRect(x:min(max(8,p.x+35),max(8,bounds.width-312)),y:min(max(8,p.y+20),max(8,bounds.height-460)),width:304,height:450)
        } else { inspector?.isHidden=true }
    }
    private func screen(_ p: CGPoint) -> CGPoint {
        let q=editor!.output(p)
        return CGPoint(x:imageFrame.minX+q.x*imageFrame.width,y:imageFrame.minY+q.y*imageFrame.height)
    }
    private func native(_ p: CGPoint) -> CGPoint {
        editor!.native(CGPoint(x:(p.x-imageFrame.minX)/imageFrame.width,y:(p.y-imageFrame.minY)/imageFrame.height))
    }
    private func hit(_ p: CGPoint) -> (DustSpot,Int)? {
        guard let editor else { return nil }
        for spot in editor.spots.reversed() {
            let handles=[spot.center,editor.offset(spot,distance:-spot.length/2,angle:spot.angle),editor.offset(spot,distance:spot.length/2,angle:spot.angle),editor.offset(spot,distance:spot.radius,angle:spot.angle + .pi/2),editor.offset(spot,distance:spot.radius+spot.feather,angle:spot.angle + .pi/2)]
            for (i,h) in handles.enumerated() {
                let q=screen(h)
                if hypot(q.x-p.x,q.y-p.y)<12 { return (spot,i) }
            }
            let q=screen(spot.center)
            if hypot(q.x-p.x,q.y-p.y)<18 { return (spot,0) }
        }
        return nil
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden,let editor,editor.enabled else { return nil }
        let p=convert(point,from:superview)
        if let inspector,!inspector.isHidden,inspector.frame.contains(p) { return super.hitTest(point) }
        return editor.adding || hit(p) != nil ? self : nil
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let editor else { return }
        NSColor.white.setStroke()
        for spot in editor.spots {
            let selected=editor.selected==spot.id
            for radius in [spot.radius,spot.radius+spot.feather] {
                let path=NSBezierPath();path.lineWidth=selected ? 1.5 : 1
                for i in 0...96 {
                    let p=screen(editor.offset(spot,distance:radius,angle:Double(i)*2 * .pi/96))
                    if i==0 { path.move(to:p) } else { path.line(to:p) }
                }
                NSColor.black.setStroke();path.lineWidth=3;path.stroke()
                NSColor.white.setStroke();path.lineWidth=selected ? 1.5 : 1;path.stroke()
            }
            let a=screen(editor.offset(spot,distance:-spot.length/2,angle:spot.angle)),b=screen(editor.offset(spot,distance:spot.length/2,angle:spot.angle))
            let path=NSBezierPath();path.move(to:a);path.line(to:b)
            NSColor.black.setStroke();path.lineWidth=3;path.stroke();NSColor.white.setStroke();path.lineWidth=1;path.stroke()
            var handles=[screen(spot.center)]
            if selected { handles += [a,b,screen(editor.offset(spot,distance:spot.radius,angle:spot.angle + .pi/2)),screen(editor.offset(spot,distance:spot.radius+spot.feather,angle:spot.angle + .pi/2))] }
            NSColor.white.setFill()
            for p in handles {
                let handle=NSBezierPath(ovalIn:CGRect(x:p.x-6,y:p.y-6,width:12,height:12))
                handle.fill();NSColor.black.setStroke();handle.lineWidth=1.5;handle.stroke()
            }
            NSColor.white.setStroke()
        }
        if let start,let end { let path=NSBezierPath();path.move(to:start);path.line(to:end);path.stroke() }
    }
    override func mouseDown(with event: NSEvent) {
        guard let editor else { return }
        let p=convert(event.locationInWindow,from:nil)
        if editor.adding { start=p;end=p }
        else if let (spot,handle)=hit(p) { editor.selected=spot.id;drag=(spot,handle,native(p));editor.resample(spot);refresh() }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let editor else { return }
        let p=convert(event.locationInWindow,from:nil)
        if start != nil { end=p;needsDisplay=true;return }
        guard let (original,handle,origin)=drag else { return }
        let q=native(p),size=editor.nativeSize,short=min(size.width,size.height)
        var spot=original
        if handle==0 {
            spot.center=CGPoint(x:original.center.x+q.x-origin.x,y:original.center.y+q.y-origin.y)
        } else {
            let dx=(q.x-spot.center.x)*size.width,dy=(q.y-spot.center.y)*size.height,d=hypot(dx,dy)/short
            if handle==1 || handle==2 { spot.length=2*d;spot.angle=atan2(dy,dx)+(handle==1 ? .pi:0) }
            if handle==3 { spot.radius=d }
            if handle==4 { spot.feather=max(0.000001,d-spot.radius) }
        }
        editor.update(spot);refresh()
    }
    override func mouseUp(with event: NSEvent) {
        if let start,let end { editor?.create(native(start),native(end)) }
        else if let spot=editor?.selectedSpot { editor?.resample(spot) }
        start=nil;end=nil;drag=nil;refresh()
    }
}
#endif

#if !os(macOS)
struct DustMobileOverlay: View {
    @Bindable var editor: DustEditor
    let aspect: Double
    @State private var start: CGPoint?
    @State private var end: CGPoint?
    @State private var original: DustSpot?
    var body: some View {
        GeometryReader { proxy in
            let frame=CropGeometry.frame(in:CGRect(origin:.zero,size:proxy.size),ratio:aspect)
            ZStack(alignment:.topTrailing) {
                Canvas { context,_ in
                    func screen(_ p:CGPoint)->CGPoint { let q=editor.output(p);return CGPoint(x:frame.minX+q.x*frame.width,y:frame.minY+q.y*frame.height) }
                    for spot in editor.spots {
                        for radius in [spot.radius,spot.radius+spot.feather] {
                            var path=Path()
                            for i in 0...96 {
                                let p=screen(editor.offset(spot,distance:radius,angle:Double(i)*2 * .pi/96))
                                if i==0 { path.move(to:p) } else { path.addLine(to:p) }
                            }
                            context.stroke(path,with:.color(.white),lineWidth:1.5)
                        }
                        var path=Path();path.move(to:screen(editor.offset(spot,distance:-spot.length/2,angle:spot.angle)));path.addLine(to:screen(editor.offset(spot,distance:spot.length/2,angle:spot.angle)))
                        context.stroke(path,with:.color(.white),lineWidth:1)
                    }
                    if let start,let end { var path=Path();path.move(to:start);path.addLine(to:end);context.stroke(path,with:.color(.white),lineWidth:1) }
                }.contentShape(Rectangle()).gesture(DragGesture(minimumDistance:0).onChanged { value in
                    func native(_ p:CGPoint)->CGPoint { editor.native(CGPoint(x:(p.x-frame.minX)/frame.width,y:(p.y-frame.minY)/frame.height)) }
                    if start==nil {
                        start=value.startLocation
                        if !editor.adding {
                            let q=native(value.startLocation)
                            original=editor.spots.min { hypot($0.center.x-q.x,$0.center.y-q.y)<hypot($1.center.x-q.x,$1.center.y-q.y) }
                            editor.selected=original?.id
                        }
                    }
                    end=value.location
                    if let original,!editor.adding {
                        let a=native(value.startLocation),b=native(value.location)
                        var spot=original;spot.center=CGPoint(x:original.center.x+b.x-a.x,y:original.center.y+b.y-a.y);editor.update(spot)
                    }
                }.onEnded { value in
                    if editor.adding {
                        let a=editor.native(CGPoint(x:(value.startLocation.x-frame.minX)/frame.width,y:(value.startLocation.y-frame.minY)/frame.height))
                        let b=editor.native(CGPoint(x:(value.location.x-frame.minX)/frame.width,y:(value.location.y-frame.minY)/frame.height))
                        editor.create(a,b)
                    } else if let spot=editor.selectedSpot { editor.resample(spot) }
                    start=nil;end=nil;original=nil
                })
                if editor.selectedSpot != nil { DustInspector(editor:editor).padding(8) }
            }
        }
    }
}
#endif
