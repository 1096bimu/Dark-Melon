import SwiftUI

struct OKLabVertexControls: View {
    @Environment(\.resetMapping) private var defaults
    @Binding var controls: [OKLabVertexAdjustment]
    let space: ProcessingColorSpace
    @State private var selected: Int?
    @State private var dragging: Int?
    @State private var graphSize = CGSize(width: 296, height: 296)
    private let names=["Red","Orange","Yellow","Green","Cyan","Blue","Magenta"]
    private let colors:[Color]=[.red,.orange,.yellow,.green,.cyan,.blue,.purple]
    private var separation: Double { EditorGraphStyle.handleSize + 2 }
    private var inner: Double {
        let hues=OKLabVertexWarp.vertexHues[space]!
        let gap=hues.indices.map { i in
            (i+1<hues.count ? hues[i+1] : hues[0]+2 * .pi)-hues[i]
        }.min()!
        return max(36, separation/(2*sin(gap/2)))
    }
    private var vertices: [SIMD3<Double>] {
        OKLabVertexWarp.field(controls:OKLabVertexWarp.defaults,space:space).centers
    }
    private func angle(_ index:Int) -> Double {
        controls[index].hueOffset ?? OKLabVertexWarp.rotationAngle(index:index,amount:controls[index].rotation,space:space)
    }
    private func radius(_ index:Int, chroma:Double, size:CGSize) -> Double {
        let outer=max(inner+1,min(size.width,size.height)/2-20)
        let vertex=vertices[index]
        return inner+(outer-inner)*hypot(vertex.y,vertex.z)*chroma/(2*OKLCHGamut.maxima[space]!)
    }
    private func point(_ index:Int, size:CGSize) -> CGPoint {
        let r=radius(index,chroma:controls[index].chroma,size:size)
        let hue=OKLabVertexWarp.vertexHues[space]![index]+angle(index)
        return CGPoint(x:size.width/2+r*cos(hue),y:size.height/2-r*sin(hue))
    }
    private func move(_ index:Int, to location:CGPoint, size:CGSize) {
        let center=CGPoint(x:size.width/2,y:size.height/2)
        let maximum=radius(index,chroma:2,size:size)
        var p=location
        // Project onto the permitted annulus and away from the other handles.
        // There are no fixed hue sectors; only actual handle proximity constrains movement.
        for _ in 0..<24 {
            var x=p.x-center.x,y=p.y-center.y
            var r=hypot(x,y)
            if r<0.0001 {
                let hue=OKLabVertexWarp.vertexHues[space]![index]
                x=cos(hue);y = -sin(hue);r=1
            }
            let bounded=min(maximum,max(inner,r))
            p=CGPoint(x:center.x+x/r*bounded,y:center.y+y/r*bounded)
            for other in controls.indices where other != index {
                let q=point(other,size:size)
                let dx=p.x-q.x,dy=p.y-q.y,d=hypot(dx,dy)
                if d<separation {
                    if d<0.0001 { return }
                    p=CGPoint(x:q.x+dx/d*separation,y:q.y+dy/d*separation)
                }
            }
        }
        let x=p.x-center.x,y=center.y-p.y,r=hypot(x,y)
        guard r>=inner-0.001, r<=maximum+0.001,
              controls.indices.filter({ $0 != index }).allSatisfy({
                  let q=point($0,size:size)
                  return hypot(p.x-q.x,p.y-q.y)>=separation-0.001
              }) else { return }
        let base=OKLabVertexWarp.vertexHues[space]![index]
        controls[index].hueOffset=atan2(sin(atan2(y,x)-base),cos(atan2(y,x)-base))
        controls[index].rotation=0
        controls[index].chroma=min(2,max(0,(r-inner)/(maximum-inner)*2))
    }
    private func setPolar(_ index:Int, chroma:Double? = nil, angle offset:Double? = nil) {
        let r=radius(index,chroma:chroma ?? controls[index].chroma,size:graphSize)
        let hue=OKLabVertexWarp.vertexHues[space]![index]+(offset ?? angle(index))
        move(index,to:CGPoint(x:graphSize.width/2+r*cos(hue),y:graphSize.height/2-r*sin(hue)),size:graphSize)
    }

    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text("OKLab Vertices").font(.headline)
                Spacer()
                Button("Monochrome") {
                    for index in controls.indices { controls[index].chroma = 0; controls[index].hueOffset = 0; controls[index].rotation = 0 }
                }
                .disabled(controls.allSatisfy { $0.chroma == 0 })
                Button("Reset") { controls=OKLabVertexWarp.defaults }
                    .disabled(controls.allSatisfy(\.isIdentity))
            }
            GeometryReader { geometry in
                let size=geometry.size
                ZStack {
                    Canvas { context,size in
                        let center=CGPoint(x:size.width/2,y:size.height/2)
                        var axes=Path()
                        axes.move(to:CGPoint(x:12,y:center.y));axes.addLine(to:CGPoint(x:size.width-12,y:center.y))
                        axes.move(to:CGPoint(x:center.x,y:12));axes.addLine(to:CGPoint(x:center.x,y:size.height-12))
                        context.stroke(axes,with:.color(EditorGraphStyle.guideColor),style:EditorGraphStyle.guide)
                        let ring=Path(ellipseIn:CGRect(x:center.x-inner,y:center.y-inner,width:inner*2,height:inner*2))
                        context.stroke(ring,with:.color(EditorGraphStyle.guideColor),style:EditorGraphStyle.guide)
                        var polygon=Path()
                        for index in 0..<OKLabVertexWarp.count {
                            let p=point(index,size:size)
                            if index==0 { polygon.move(to:p) } else { polygon.addLine(to:p) }
                        }
                        polygon.closeSubpath()
                        context.stroke(polygon,with:.color(.secondary.opacity(0.5)),lineWidth:EditorGraphStyle.line)
                        context.draw(Text("0").font(.caption).foregroundStyle(.secondary),at:center)
                        context.draw(Text("a").font(.caption).foregroundStyle(.secondary),at:CGPoint(x:size.width-8,y:center.y+12))
                        context.draw(Text("b").font(.caption).foregroundStyle(.secondary),at:CGPoint(x:center.x+12,y:8))
                    }
                    ForEach(0..<OKLabVertexWarp.count) { index in
                        EditorGraphHandle(color:colors[index], selected:selected==index, isDragging: dragging == index)
                            .controlReset {
                                selected = index
                                controls[index].chroma = defaults.vertexWarp[index].chroma
                                controls[index].hueOffset = defaults.vertexWarp[index].hueOffset
                                controls[index].rotation = defaults.vertexWarp[index].rotation
                            }
                            .position(point(index,size:size))
                            .accessibilityLabel(Text(LocalizedStringKey(names[index])))
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { selected=index }
                    }
                }
                .coordinateSpace(name:"vertexGraph")
                .gesture(DragGesture(minimumDistance:0,coordinateSpace:.named("vertexGraph"))
                    .onChanged { value in
                        if dragging==nil {
                            let nearest=(0..<OKLabVertexWarp.count).min { hypot(point($0,size:size).x-value.startLocation.x,point($0,size:size).y-value.startLocation.y)<hypot(point($1,size:size).x-value.startLocation.x,point($1,size:size).y-value.startLocation.y) }!
                            let p=point(nearest,size:size)
                            guard hypot(p.x-value.startLocation.x,p.y-value.startLocation.y)<24 else { return }
                            dragging=nearest;selected=nearest
                        }
                        if let dragging, hypot(value.translation.width,value.translation.height)>2 { move(dragging,to:value.location,size:size) }
                    }.onEnded { _ in dragging=nil })
            }.aspectRatio(1,contentMode:.fit)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { graphSize = $0 }
            .overlay {
                if let selected {
                    VStack {
                HStack {
                    Label { Text(LocalizedStringKey(names[selected])).fontWeight(.medium) }
                        icon: { Circle().fill(colors[selected]).frame(width:10,height:10) }
                    Spacer()
                }
                        Spacer()
                        HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Chroma")
                    AdjustmentField(title: "Chroma", value: Binding(get: { controls[selected].chroma }, set: { setPolar(selected, chroma: $0) }), range: 0...2, unit: "×")
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text("Hue")
                    AdjustmentField(title: "Hue", value: Binding(get: {
                        angle(selected)*180 / .pi
                    }, set: { degrees in
                        setPolar(selected, angle: degrees * .pi/180)
                    }), range: -180...180, digits: 1, unit: "°")
                }
                        }
                    }.padding(4)
                }
            }

            if let selected {
                HStack {
                    Text("Lightness")
                    Spacer()
                    AdjustmentField(title: "Lightness", value: $controls[selected].lightness, range: -0.25...0.25, digits: 3)
                }
                EditorSlider(value:$controls[selected].lightness,in: -0.25...0.25) { Text("Lightness") }.controlReset { controls[selected].lightness = defaults.vertexWarp[selected].lightness }.labelsHidden()
            }
        }
    }
}
