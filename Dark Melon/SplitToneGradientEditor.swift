import SwiftUI

struct SplitToneGradientEditor: View {
    @Binding var settings: SplitToneSettings
    let space: ProcessingColorSpace
    let ceiling: Double
    @State private var selection: UUID?
    @State private var rotatingHue: Bool?
    private var maximum: Double { cbrt(ceiling) }
    private var nodes: [SplitToneNode] { settings.nodes ?? [] }
    private var selected: SplitToneNode? { nodes.first{$0.id==selection} }
    private func update(_ action:(inout SplitToneNode)->Void) {
        guard let index=settings.nodes?.firstIndex(where:{$0.id==selection}) else { return }
        action(&settings.nodes![index])
    }
    private func remove(_ id: UUID) {
        settings.nodes?.removeAll{$0.id==id}
        if selection==id { selection=settings.nodes?.first?.id }
    }
    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { proxy in
                let width=max(1,proxy.size.width-20)
                ZStack(alignment: .leading) {
                    LinearGradient(colors:(0...32).map{Color(white:Double($0)/32)},startPoint:.leading,endPoint:.trailing)
                        .frame(height:30).padding(.horizontal,10)
                        .contentShape(Rectangle())
                        .gesture(SpatialTapGesture().onEnded { tap in
                            let lightness=((tap.location.x-10)/width).clamped(to:0...1)*maximum
                            if let nearby=nodes.min(by:{abs($0.lightness-lightness)<abs($1.lightness-lightness)}), abs(nearby.lightness-lightness)/maximum*width<12 {
                                selection=nearby.id
                            } else if nodes.count<6 {
                                let node=SplitToneNode(lightness:lightness)
                                settings.nodes=(settings.nodes ?? [])+[node];selection=node.id
                            }
                        })
                    Path { path in
                        let x=10+width/maximum
                        path.move(to:CGPoint(x:x,y:0))
                        path.addLine(to:CGPoint(x:x,y:40))
                    }.stroke(.white,style:StrokeStyle(lineWidth:1,dash:[3,2]))
                        .allowsHitTesting(false)
                    Text("SDR white")
                        .font(.caption2).foregroundStyle(.secondary)
                        .position(x:min(proxy.size.width-32,max(32,10+width/maximum)),y:49)
                        .allowsHitTesting(false)
                    ForEach(nodes) { node in
                        Circle().fill(node.id==selection ? Color.accentColor : .white)
                            .overlay(Circle().stroke(.black,lineWidth:2)).frame(width:16,height:16)
                            .frame(width:24,height:40).contentShape(Rectangle())
                            .position(x:10+min(1,node.lightness/maximum)*width,y:20)
                            .onTapGesture { selection=node.id }
                            .gesture(DragGesture(minimumDistance:3,coordinateSpace:.named("toneGradient")).onChanged { value in
                                selection=node.id
                                update { $0.lightness=((value.location.x-10)/width).clamped(to:0...1)*maximum }
                            })
                            .contextMenu { Button("Delete Node",role:.destructive) { remove(node.id) } }
                            .accessibilityLabel("Tone node")
                            .accessibilityValue(node.lightness.formatted())
                    }
                }.frame(height:40)
            }.coordinateSpace(name:"toneGradient").frame(height:60)
            HStack {
                Text("Black")
                Spacer()
                Text(ceiling>1 ? "HDR" : "SDR")
                Text(maximum,format:.number.precision(.fractionLength(3)))
            }.font(.caption).foregroundStyle(.secondary)
            if let node=selected {
                HStack {
                    Text("Lightness")
                    Slider(value:Binding(get:{selected?.lightness ?? 0},set:{new in update{$0.lightness=new}}),in:0...maximum)
                    Text(node.lightness,format:.number.precision(.fractionLength(3))).monospacedDigit()
                }
                wheel(node).frame(height:230)
                HStack {
                    Text("Hue")
                    Text(node.hue,format:.number.precision(.fractionLength(0)))
                    Spacer()
                    Text(node.strength,format:.percent.precision(.fractionLength(0)))
                    Button("Delete Node",role:.destructive) { remove(node.id) }
                }.font(.caption)
            } else {
                Text("Click the gradient to add a tone node.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { if selection==nil { selection=nodes.first?.id } }
    }
    private func wheel(_ node:SplitToneNode)->some View {
        GeometryReader { proxy in
            let size=min(proxy.size.width,proxy.size.height)
            let center=CGPoint(x:proxy.size.width/2,y:proxy.size.height/2)
            let radius=size/2-14
            let innerRadius=radius-18
            let hueRadius=radius-9
            // Leave a visible gap even at 100% strength.
            let strengthRadius=innerRadius-22
            let angle=node.hue*Double.pi/180
            ZStack {
                Canvas { context,_ in
                    for i in 0..<120 {
                        let hue=Double(i)*3
                        let maxC=OKLabColor.maximumChroma(lightness:node.lightness,hue:hue+1.5,ceiling:ceiling,space:space)
                        let radians=(hue+1.5)*Double.pi/180
                        let rgb=OKLabColor.linear(SIMD3(node.lightness,maxC*cos(radians),maxC*sin(radians)),space:.sRGB)/ceiling
                        let color=Color(.sRGBLinear,red:max(0,min(1,rgb.x)),green:max(0,min(1,rgb.y)),blue:max(0,min(1,rgb.z)),opacity:1)
                        var path=Path()
                        path.addArc(center:center,radius:radius,startAngle:.degrees(-hue-3),endAngle:.degrees(-hue),clockwise:false)
                        path.addArc(center:center,radius:innerRadius,startAngle:.degrees(-hue),endAngle:.degrees(-hue-3),clockwise:true)
                        path.closeSubpath();context.fill(path,with:.color(color))
                    }
                    var line=Path();line.move(to:center)
                    line.addLine(to:CGPoint(x:center.x+strengthRadius*cos(angle),y:center.y-strengthRadius*sin(angle)))
                    context.stroke(line,with:.color(.secondary),lineWidth:2)
                }
                Circle().fill(.white).overlay(Circle().stroke(.black,lineWidth:2))
                    .frame(width:16,height:16)
                    .position(x:center.x+hueRadius*cos(angle),y:center.y-hueRadius*sin(angle))
                    .accessibilityLabel("Hue")
                    .accessibilityValue(node.hue.formatted())
                    .accessibilityAdjustableAction { direction in
                        update { $0.hue=($0.hue+(direction == .increment ? 1 : 359)).truncatingRemainder(dividingBy:360) }
                    }
                Circle().fill(.white).overlay(Circle().stroke(.black,lineWidth:2))
                    .frame(width:12,height:12)
                    .position(x:center.x+strengthRadius*node.strength*cos(angle),y:center.y-strengthRadius*node.strength*sin(angle))
                    .accessibilityLabel("Tone strength")
                    .accessibilityValue(node.strength.formatted(.percent))
                    .accessibilityAdjustableAction { direction in
                        update { $0.strength=($0.strength+(direction == .increment ? 0.01 : -0.01)).clamped(to:0...1) }
                    }
            }
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance:0).onChanged { value in
                let x=value.location.x-center.x,y=center.y-value.location.y
                if rotatingHue == nil {
                    let start=value.startLocation
                    rotatingHue=hypot(start.x-center.x,start.y-center.y) >= innerRadius-8
                }
                update {
                    if rotatingHue == true {
                        $0.hue=(atan2(y,x)*180 / .pi+360).truncatingRemainder(dividingBy:360)
                    } else {
                        $0.strength=((x*cos(angle)+y*sin(angle))/strengthRadius).clamped(to:0...1)
                    }
                }
            }.onEnded { _ in rotatingHue=nil })
        }
    }
}
