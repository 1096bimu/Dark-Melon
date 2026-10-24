import SwiftUI

/// Periodic hue axis: duplicated edge handles share the same control and drag state.
struct MountainRangeHandles: View {
    @Binding var controls: [OKLabVertexAdjustment]
    @Binding var selected: Int?
    let space: ProcessingColorSpace
    let maximumChroma: Double
    let scale: Double
    var lightnessMode = false
    var boundary: [Double] = []
    var movementEnabled = true
    var densityMode = false
    @State private var drag: DragStart?
    private struct DragStart {
        let index: Int
        let upper: Bool
        let hue: Double
        let chroma: Double
        let lightness: Double
    }
    static let colors: [Color] = [.red,.orange,.yellow,.green,.cyan,.blue,.purple]
    static let names = ["Red","Orange","Yellow","Green","Cyan","Blue","Magenta"]
    private var slices: [ColorSliceGeometry.Slice] { ColorSliceGeometry.cache[space]! }
    private func base(_ i: Int) -> Double {
        controls[i].hueOffset ?? OKLabVertexWarp.rotationAngle(index:i,amount:controls[i].rotation,space:space)
    }
    private func hue(_ i: Int, upper: Bool) -> Double {
        slices[i].hue+base(i)+(lightnessMode ? (upper ? controls[i].lighterHue:controls[i].darkerHue) : 0)
    }
    private func ceiling(_ angle: Double) -> Double {
        guard !boundary.isEmpty else { return maximumChroma / scale }
        let turn=angle/(2 * .pi)
        let position=(turn-floor(turn))*Double(boundary.count)
        let index=Int(position), fraction=position-Double(index)
        return boundary[index]*(1-fraction)+boundary[(index+1)%boundary.count]*fraction
    }
    private func point(_ i: Int, upper: Bool, size: CGSize) -> CGPoint {
        let angle=movementEnabled ? hue(i,upper:upper) : slices[i].hue
        let wrapped=angle-floor(angle/(2 * .pi))*2 * .pi
        let y: Double
        if densityMode { y=0.5-controls[i].lightness*2 }
        else if lightnessMode { y=1-(upper ? slices[i].upper:slices[i].lower) }
        else { y=1-ceiling(angle)*(movementEnabled ? controls[i].chroma : 0)/2*scale/maximumChroma }
        return CGPoint(x:wrapped/(2 * .pi)*size.width,y:min(1,max(0,y))*size.height)
    }
    var body: some View {
        GeometryReader { geometry in
            let size=geometry.size
            ZStack {
                ForEach(controls.indices, id: \.self) { i in
                    ForEach(lightnessMode ? [false,true] : [false], id: \.self) { upper in
                        let p=point(i,upper:upper,size:size)
                        ForEach(-1...1,id: \.self) { copy in
                            let x=p.x+Double(copy)*size.width
                            if x >= -14 && x <= size.width+14 {
                                EditorGraphHandle(color:Self.colors[i],selected:selected==i)
                                    .position(x:x,y:p.y)
                                    .accessibilityLabel(Text(LocalizedStringKey(Self.names[i])))
                                    .gesture(DragGesture(minimumDistance:0)
                                        .onChanged { value in
                                            selected=i
                                            guard movementEnabled || densityMode else { return }
                                            if drag == nil {
                                                drag=DragStart(index:i,upper:upper,hue:hue(i,upper:upper),chroma:controls[i].chroma,lightness:controls[i].lightness)
                                            }
                                            guard let start=drag,start.index==i,start.upper==upper else { return }
                                            if densityMode {
                                                let offset=start.lightness-value.translation.height/max(1,size.height)*0.5
                                                controls[i].lightness=offset.clamped(to: -0.25...0.25)
                                                return
                                            }
                                            let target=start.hue+value.translation.width/max(1,size.width)*2 * .pi
                                            if lightnessMode {
                                                let offset=(target-slices[i].hue-base(i)).clamped(to: -Double.pi...Double.pi)
                                                if upper { controls[i].lighterHue=offset } else { controls[i].darkerHue=offset }
                                            } else {
                                                let c=ceiling(target)
                                                let amount=(start.chroma-value.translation.height/max(1,size.height)*maximumChroma*2/(max(c,0.00001)*scale)).clamped(to:0...2)
                                                let offset=(target-slices[i].hue).clamped(to: -Double.pi...Double.pi)
                                                let wrapped=(slices[i].hue+offset)/(2 * .pi)
                                                let newX=(wrapped-floor(wrapped))*size.width
                                                let newY=(1-c*amount/2*scale/maximumChroma)*size.height
                                                // Periodic collision spacing; no fixed hue sectors.
                                                let allowed=controls.indices.filter { $0 != i }.allSatisfy { other in
                                                    let q=point(other,upper:false,size:size)
                                                    let dx=abs(newX-q.x)
                                                    return hypot(min(dx,size.width-dx),newY-q.y)>=EditorGraphStyle.handleSize
                                                }
                                                if allowed {
                                                    controls[i].hueOffset=offset;controls[i].rotation=0
                                                    controls[i].chroma=amount
                                                }
                                            }
                                        }.onEnded { _ in drag=nil })
                            }
                        }
                    }
                }
            }
        }
    }
}

struct LightnessHueControls: View {
    @Binding var controls: [OKLabVertexAdjustment]
    @Binding var selected: Int?
    let space: ProcessingColorSpace
    var texture: ScopeTexture?
    var hover: CGPoint?
    var gradient: ScopeGradient
    @State private var outline: [ColorSliceGeometry.Slice] = []
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            HStack {
                Text("Darker / Lighter Hue").fontWeight(.medium)
                Spacer()
                Text("C 0.1 · SDR").font(.caption).foregroundStyle(.secondary)
            }
            ZStack {
                Color.black
                if let texture { ScopeMetalView(frame:texture,gradient:gradient) }
                Canvas { context,size in
                    for i in OKLabVertexWarp.vertexHues[space]!.indices {
                        let hue=OKLabVertexWarp.vertexHues[space]![i]
                        let x=hue/(2 * .pi)*size.width
                        var guide=Path()
                        guide.move(to:CGPoint(x:x,y:0));guide.addLine(to:CGPoint(x:x,y:size.height))
                        context.stroke(guide,with:.color(EditorGraphStyle.guideColor),style:EditorGraphStyle.guide)
                    }
                    for upper in [false,true] {
                        var line=Path()
                        for (i,slice) in outline.enumerated() {
                            let p=CGPoint(x:Double(i)/72*size.width,y:(1-(upper ? slice.upper:slice.lower))*size.height)
                            if i==0 { line.move(to:p) } else { line.addLine(to:p) }
                        }
                        context.stroke(line,with:.color(EditorGraphStyle.guideColor),style:EditorGraphStyle.guide)
                    }
                    context.draw(Text("1").font(.caption2).foregroundStyle(.secondary),at:CGPoint(x:6,y:8))
                    context.draw(Text("0").font(.caption2).foregroundStyle(.secondary),at:CGPoint(x:6,y:size.height-8))
                }.allowsHitTesting(false)
                ScopePixelMarker(position:hover)
                MountainRangeHandles(controls:$controls,selected:$selected,space:space,
                    maximumChroma:1,scale:1,lightnessMode:true)
            }.aspectRatio(1.6,contentMode:.fit)
            .help("Drag horizontally to bend darker and lighter hues. Positions use the unedited SDR gamut at chroma 0.1.")
            if let i=selected {
                HStack {
                    Text(LocalizedStringKey(MountainRangeHandles.names[i])).foregroundStyle(MountainRangeHandles.colors[i])
                    Spacer()
                }
                HStack {
                    Text("Darker")
                    AdjustmentField(title:"Darker",value:$controls[i].darkerHue,range: -Double.pi...Double.pi,digits:1,scale:180 / .pi,unit:"°",width:52)
                    Spacer()
                    Text("Lighter")
                    AdjustmentField(title:"Lighter",value:$controls[i].lighterHue,range: -Double.pi...Double.pi,digits:1,scale:180 / .pi,unit:"°",width:52)
                }.font(.caption)
            }
        }
        .task(id:space) {
            let selectedSpace=space
            let result=await Task.detached(priority:.userInitiated) {
                (0...72).map { ColorSliceGeometry.slice(hue:Double($0)/72*2 * .pi,space:selectedSpace) }
            }.value
            guard !Task.isCancelled else { return }
            outline=result
        }
    }
}

/// Normalized scope coordinates; repeats across the hue seam.
struct ScopePixelMarker: View {
    let position: CGPoint?

    static func draw(in context: inout GraphicsContext, at point: CGPoint, color: Color = .white) {
        let ring = Path(ellipseIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10))
        context.stroke(ring, with: .color(.black), lineWidth: 4)
        context.stroke(ring, with: .color(color), lineWidth: 2)
    }

    var body: some View {
        Canvas { context,size in
            guard let position else { return }
            for copy in -1...1 {
                let point=CGPoint(x:(position.x+Double(copy))*size.width,y:min(1,max(0,position.y))*size.height)
                Self.draw(in: &context, at: point)
            }
        }.allowsHitTesting(false)
    }
}
