import SwiftUI

struct OKLabVertexControls: View {
    @Binding var controls: [OKLabVertexAdjustment]
    let space: ProcessingColorSpace
    @State private var selected: Int?
    @State private var dragging: Int?
    private let names=["Red","Yellow","Green","Cyan","Blue","Magenta"]
    private let colors:[Color]=[.red,.yellow,.green,.cyan,.blue,.purple]

    private var vertices: [SIMD3<Double>] {
        OKLabVertexWarp.field(controls:Array(repeating:OKLabVertexAdjustment(),count:6),space:space).centers
    }
    private func point(_ index:Int, size:CGSize) -> CGPoint {
        let inner=36.0, outer=max(inner+1,min(size.width,size.height)/2-20)
        let vertex=vertices[index]
        let c=hypot(vertex.y,vertex.z)*controls[index].chroma
        let radius=inner+(outer-inner)*c/(2*OKLCHGamut.maxima[space]!)
        // Fan handles apart near zero; at zero each retains its own hue slot.
        let fan=min(1,max(0,(radius-inner)/24))
        let hue=OKLabVertexWarp.vertexHues[space]![index]
            + OKLabVertexWarp.rotationAngle(index:index,amount:controls[index].rotation,space:space)*fan
        return CGPoint(x:size.width/2+radius*cos(hue),y:size.height/2-radius*sin(hue))
    }
    private func move(_ index:Int, to location:CGPoint, size:CGSize) {
        let inner=36.0, outer=max(inner+1,min(size.width,size.height)/2-20)
        let x=location.x-size.width/2,y=size.height/2-location.y
        let radius=hypot(x,y), vertex=vertices[index]
        controls[index].chroma=max(0,min(2,(radius-inner)/(outer-inner)*2*OKLCHGamut.maxima[space]!/hypot(vertex.y,vertex.z)))
        let displayedRadius=inner+(outer-inner)*hypot(vertex.y,vertex.z)*controls[index].chroma/(2*OKLCHGamut.maxima[space]!)
        let fan=min(1,max(0,(displayedRadius-inner)/24))
        guard fan>0.01 else { return }
        let original=OKLabVertexWarp.vertexHues[space]![index]
        let delta=atan2(sin(atan2(y,x)-original),cos(atan2(y,x)-original))
        let limit=abs(OKLabVertexWarp.rotationAngle(index:index,amount:delta<0 ? -1:1,space:space))
        controls[index].rotation=max(-1,min(1,delta/(limit*fan)))
    }

    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text("OKLab Vertices").font(.headline)
                Spacer()
                Button("Reset") { controls=Array(repeating:OKLabVertexAdjustment(),count:6) }
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
                        context.stroke(axes,with:.color(.secondary.opacity(0.2)))
                        let ring=Path(ellipseIn:CGRect(x:center.x-36,y:center.y-36,width:72,height:72))
                        context.stroke(ring,with:.color(.secondary.opacity(0.5)),style:StrokeStyle(lineWidth:1,dash:[3,3]))
                        if let selected {
                            let inner=36.0,outer=max(inner+1,min(size.width,size.height)/2-20)
                            let v=vertices[selected], radius=inner+(outer-inner)*hypot(v.y,v.z)/OKLCHGamut.maxima[space]!
                            let hue=OKLabVertexWarp.vertexHues[space]![selected]
                            var sector=Path()
                            // Sample the allowed handle region, including the zero-chroma fan.
                            for side in [-1.0,1.0] {
                                if side>0 {
                                    for step in 0...40 {
                                        let amount = -1.0+2.0*Double(step)/40
                                        let angle=hue+OKLabVertexWarp.rotationAngle(index:selected,amount:amount,space:space)*min(1,(radius-inner)/24)
                                        sector.addLine(to:CGPoint(x:center.x+radius*cos(angle),y:center.y-radius*sin(angle)))
                                    }
                                }
                                for step in 0...40 {
                                    let t=Double(side<0 ? step:40-step)/40
                                    let r=inner+(radius-inner)*t
                                    let angle=hue+OKLabVertexWarp.rotationAngle(index:selected,amount:side,space:space)*min(1,(r-inner)/24)
                                    let p=CGPoint(x:center.x+r*cos(angle),y:center.y-r*sin(angle))
                                    if side<0 && step==0 { sector.move(to:p) } else { sector.addLine(to:p) }
                                }
                            }
                            sector.closeSubpath()
                            context.fill(sector,with:.color(colors[selected].opacity(0.12)))
                            context.stroke(sector,with:.color(colors[selected].opacity(0.4)))
                        }
                        var polygon=Path()
                        for index in 0..<6 {
                            let p=point(index,size:size)
                            if index==0 { polygon.move(to:p) } else { polygon.addLine(to:p) }
                        }
                        polygon.closeSubpath()
                        context.stroke(polygon,with:.color(.secondary.opacity(0.5)))
                        context.draw(Text("0").font(.caption).foregroundStyle(.secondary),at:center)
                        context.draw(Text("a").font(.caption).foregroundStyle(.secondary),at:CGPoint(x:size.width-8,y:center.y+12))
                        context.draw(Text("b").font(.caption).foregroundStyle(.secondary),at:CGPoint(x:center.x+12,y:8))
                    }
                    ForEach(0..<6) { index in
                        Circle().fill(colors[index])
                            .overlay(Circle().strokeBorder(selected==index ? Color.primary:Color.black.opacity(0.6),lineWidth:selected==index ? 3:1))
                            .frame(width:18,height:18)
                            .frame(width:28,height:28).contentShape(Circle())
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
                            let nearest=(0..<6).min { hypot(point($0,size:size).x-value.startLocation.x,point($0,size:size).y-value.startLocation.y)<hypot(point($1,size:size).x-value.startLocation.x,point($1,size:size).y-value.startLocation.y) }!
                            let p=point(nearest,size:size)
                            guard hypot(p.x-value.startLocation.x,p.y-value.startLocation.y)<24 else { return }
                            dragging=nearest;selected=nearest
                        }
                        if let dragging, hypot(value.translation.width,value.translation.height)>2 { move(dragging,to:value.location,size:size) }
                    }.onEnded { _ in dragging=nil })
            }.aspectRatio(1,contentMode:.fit)
            if let selected {
                HStack {
                    Label { Text(LocalizedStringKey(names[selected])).fontWeight(.medium) }
                        icon: { Circle().fill(colors[selected]).frame(width:10,height:10) }
                    Spacer()
                    Button("Reset") { controls[selected]=OKLabVertexAdjustment() }
                        .disabled(controls[selected].isIdentity)
                }
                HStack {
                    Text("Lightness")
                    Spacer()
                    Text(controls[selected].lightness,format:.number.precision(.fractionLength(3))).monospacedDigit()
                }
                Slider(value:$controls[selected].lightness,in: -0.25...0.25) { Text("Lightness") }.labelsHidden()
            }
        }
    }
}
