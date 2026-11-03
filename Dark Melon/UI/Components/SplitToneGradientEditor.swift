import SwiftUI

struct SplitToneGradientEditor: View {
    @Environment(\.resetMapping) private var defaults
    @Binding var settings: SplitToneSettings
    let space: ProcessingColorSpace
    let ceiling: Double
    @State private var selection: UUID?
    @GestureState private var draggingNode: UUID?
    @GestureState private var draggingWheel = false
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
                    Capsule().fill(EditorSliderTracks.tone)
                        .frame(height: EditorGraphStyle.trackWidth)
                        .frame(height: 40)
                        .padding(.horizontal,10)
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
                    }.stroke(.white,style:EditorGraphStyle.guide)
                        .allowsHitTesting(false)
                    Text("SDR white")
                        .font(.caption2).foregroundStyle(.secondary)
                        .position(x:min(proxy.size.width-32,max(32,10+width/maximum)),y:49)
                        .allowsHitTesting(false)
                    ForEach(nodes) { node in
                        EditorGraphHandle(color: nodeTint(node), selected: node.id==selection, isDragging: draggingNode == node.id)
                            .controlReset {
                                selection = node.id
                                update { $0.lightness = defaults.color.splitTone.nodes?.first(where: { $0.id == node.id })?.lightness ?? maximum / 2 }
                            }
                            .position(x:10+min(1,node.lightness/maximum)*width,y:20)
                            .onTapGesture { selection=node.id }
                            .gesture(DragGesture(minimumDistance:3,coordinateSpace:.named("toneGradient"))
                                .updating($draggingNode) { _, state, _ in state = node.id }
                                .onChanged { value in
                                selection=node.id
                                update { $0.lightness=((value.location.x-10)/width).clamped(to:0...1)*maximum }
                            })
                            .contextMenu { Button("Delete Node",role:.destructive) { remove(node.id) } }
                            .accessibilityLabel("Tone node")
                            .accessibilityValue(node.lightness.formatted())
                    }
                }.frame(height:40)
            }.coordinateSpace(name:"toneGradient").frame(height:60).modifier(DisabledControlAppearance())
            HStack {
                Text("Black")
                Spacer()
                Text(ceiling>1 ? "HDR" : "SDR")
                Text(maximum,format:.number.precision(.fractionLength(3)))
            }.font(.caption).foregroundStyle(.secondary)
            if let node=selected {
                wheel(node).frame(height:230).modifier(DisabledControlAppearance())
                HStack {
                    Text("Hue")
                    AdjustmentField(title: "Hue", value: Binding(get: { selected?.hue ?? 0 }, set: { v in update { $0.hue=v } }), range: 0...360, digits: 0, unit: "°")
                    Spacer()
                    Text("Strength")
                    AdjustmentField(title: "Strength", value: Binding(get: { selected?.strength ?? 0 }, set: { v in update { $0.strength=v } }), range: 0...1, digits: 0, scale: 100, unit: "%")
                }
                Button("Delete Node",role:.destructive) { remove(node.id) }
            } else {
                Text("Click the gradient to add a tone node.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { if selection==nil { selection=nodes.first?.id } }
    }
    private func nodeTint(_ node: SplitToneNode) -> Color {
        // A fixed mid-lightness, full-chroma swatch keeps every hue identifiable,
        // even for zero-strength nodes and nodes at black or white.
        let l=0.7
        let c=OKLabColor.maximumChroma(lightness:l,hue:node.hue,ceiling:1,space:.sRGB)
        let angle=node.hue * .pi/180
        let rgb=OKLabColor.linear(SIMD3(l,c*cos(angle),c*sin(angle)),space:.sRGB)
        return Color(.sRGBLinear,red:rgb.x.clamped(to:0...1),green:rgb.y.clamped(to:0...1),blue:rgb.z.clamped(to:0...1))
    }

    private func wheel(_ node:SplitToneNode)->some View {
        GeometryReader { proxy in
            let size=min(proxy.size.width,proxy.size.height)
            let center=CGPoint(x:proxy.size.width/2,y:proxy.size.height/2)
            let radius=size/2-14
            let innerRadius=radius-18
            let hueRadius=radius-9
            let strengthRadius=radius
            let strengthPosition=SplitToneStrengthScale.position(node.strength)
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
                        path.addArc(center:center,radius:radius,startAngle:.degrees(-hue-3.5),endAngle:.degrees(-hue+0.5),clockwise:false)
                        path.addArc(center:center,radius:innerRadius,startAngle:.degrees(-hue+0.5),endAngle:.degrees(-hue-3.5),clockwise:true)
                        path.closeSubpath();context.fill(path,with:.color(color))
                    }
                    var line=Path();line.move(to:center)
                    line.addLine(to:CGPoint(x:center.x+strengthRadius*cos(angle),y:center.y-strengthRadius*sin(angle)))
                    context.stroke(line,with:.linearGradient(Gradient(colors: [.gray, nodeTint(node)]),
                        startPoint:center,endPoint:CGPoint(x:center.x+strengthRadius*cos(angle),y:center.y-strengthRadius*sin(angle))),
                        style:EditorGraphStyle.trackStroke)
                    for r in [radius, innerRadius] {
                        let rim=Path(ellipseIn:CGRect(x:center.x-r,y:center.y-r,width:2*r,height:2*r))
                        context.stroke(rim,with:.color(.primary.opacity(0.3)),lineWidth:EditorGraphStyle.rim)
                    }
                }
                Circle()
                    .stroke(LinearGradient(colors: [.white.opacity(0.22), .clear, .black.opacity(0.18)], startPoint: .top, endPoint: .bottom), lineWidth: 18)
                    .frame(width:2*hueRadius,height:2*hueRadius)
                    .allowsHitTesting(false)
                EditorGraphHandle(color: nodeTint(node), isDragging: draggingWheel)
                    .controlReset {
                        update {
                            if let saved = defaults.color.splitTone.nodes?.first(where: { $0.id == node.id }) {
                                $0.hue = saved.hue; $0.strength = saved.strength
                            } else { $0.strength = 0 }
                        }
                    }
                    .position(x:center.x+strengthRadius*strengthPosition*cos(angle),
                              y:center.y-strengthRadius*strengthPosition*sin(angle))
                    .accessibilityLabel("Hue and Strength")
                    .accessibilityValue(Text("\(node.hue, specifier: "%.0f")° · \(node.strength * 100, specifier: "%.0f")%"))
                    .accessibilityAdjustableAction { direction in
                        update { $0.strength=($0.strength+(direction == .increment ? 0.01 : -0.01)).clamped(to:0...1) }
                    }

            }
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance:0)
                .updating($draggingWheel) { _, state, _ in state = true }
                .onChanged { value in
                    let x=value.location.x-center.x,y=center.y-value.location.y
                    let distance=hypot(x,y)
                    update {
                        // Hue is undefined at the neutral center; retain it there.
                        if distance > 1 { $0.hue=(atan2(y,x)*180 / .pi+360).truncatingRemainder(dividingBy:360) }
                        $0.strength=SplitToneStrengthScale.strength(distance/strengthRadius)
                    }
                })
        }
    }
}

/// A logarithmic radius gives about half the travel to the first 10% of tint.
nonisolated enum SplitToneStrengthScale {
    static func position(_ strength: Double) -> Double {
        log1p(99 * strength.clamped(to: 0...1)) / log(100)
    }
    static func strength(_ position: Double) -> Double {
        (expm1(log(100) * position.clamped(to: 0...1)) / 99).clamped(to: 0...1)
    }
}
