import SwiftUI
import simd

/// Maximum chroma over all lightness values, projected onto hue/chroma.
/// Sample the RGB cube surface once per gamut; this is not a fixed-L gamut slice.
private actor HueChromaBoundary {
    static let shared = HueChromaBoundary()
    private var cache: [ProcessingColorSpace: [Double]] = [:]
    func values(_ space: ProcessingColorSpace) -> [Double] {
        if let cached = cache[space] { return cached }
        let matrix = ScopeProjection.matrix(.sRGB).inverse * ScopeProjection.matrix(space)
        let bins = 360, steps = 96
        var result = [Double](repeating: 0, count: bins)
        for axis in 0..<3 {
            for face in [0.0, 1.0] {
                for i in 0...steps {
                    for j in 0...steps {
                        var rgb = SIMD3<Double>(repeating: 0)
                        rgb[axis] = face
                        rgb[(axis+1)%3] = Double(i)/Double(steps)
                        rgb[(axis+2)%3] = Double(j)/Double(steps)
                        let lab = OKLabVertexWarp.lab(matrix*rgb)
                        let chroma = hypot(lab.y,lab.z)
                        guard chroma > 0.00001 else { continue }
                        var hue = atan2(lab.z,lab.y)/(2 * .pi)
                        if hue < 0 { hue += 1 }
                        let bin = min(bins-1, Int(hue*Double(bins)))
                        result[bin] = max(result[bin],chroma)
                    }
                }
            }
        }
        let sampled = result
        for i in 0..<bins where result[i] == 0 {
            let before = (1..<bins).first { sampled[(i-$0+bins)%bins] > 0 }!
            let after = (1..<bins).first { sampled[(i+$0)%bins] > 0 }!
            result[i] = (sampled[(i-before+bins)%bins]*Double(after)
                         + sampled[(i+after)%bins]*Double(before))/Double(before+after)
        }
        cache[space] = result
        return result
    }
}

struct HueChromaScope: View {
    @Environment(\.resetMapping) private var defaults
    @Binding var controls: [OKLabVertexAdjustment]
    @Binding var monochrome: Bool
    @State private var selected: Int?
    let source: CGImage?
    let revision: UUID
    let space: ProcessingColorSpace
    let headroom: Double
    let hdr: Bool
    let hoverTransform: TransformSettings?
    @State private var lightnessTexture: ScopeTexture?
    @AppStorage("showHueTwister") private var showHueTwister = false
    @AppStorage(ScopeGradient.preferenceKey) private var gradient = ScopeGradient.inferno
    @State private var worker: GPUVectorscope?
    @State private var texture: ScopeTexture?
    @State private var boundary: [Double] = []
    @State private var error: String?
    private var scale: Double { cbrt(hdr ? max(1, headroom) : 1) }
    private var showsTwister: Bool { showHueTwister && !monochrome }
    private var maximum: Double { OKLCHGamut.maxima[space]! * scale }
    private struct Request: Equatable {
        let revision: UUID
        let space: ProcessingColorSpace
        let maximum: Double
        let hdr: Bool
        let hasSource: Bool
        let showHueTwister: Bool
        let monochrome: Bool
    }
    private func marker(lightness: Bool) -> some View {
        HuePixelOverlay(source: source, revision: revision, space: space, transform: hoverTransform,
                        lightness: lightness, maximum: maximum, scale: monochrome ? 1 : scale)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(monochrome ? "Source · OKLCH" : "OKLCH").fontWeight(.medium)
                Spacer()
                Text(hdr ? "HDR" : "SDR").foregroundStyle(.secondary)
            }
            HStack {
                Text(monochrome ? "Lightness" : "Chroma")
                Spacer()
                Text(monochrome ? 1 : maximum, format: .number.precision(.fractionLength(3)))
            }.font(.caption).foregroundStyle(.secondary)
            Canvas { context, size in
                for (index, hue) in OKLabVertexWarp.vertexHues[space]!.enumerated().filter { $0.offset != 1 }.map(\.element).enumerated() {
                    let x = size.width * hue.truncatingRemainder(dividingBy: 2 * .pi) / (2 * .pi)
                    context.draw(Text(EditorGraphStyle.colorNames[index]).font(.caption2.bold())
                        .foregroundStyle(EditorGraphStyle.colorLabels[index]),
                        at: CGPoint(x: x, y: size.height / 2))
                }
            }.frame(height: 14)
            ZStack {
                Color.black
                if let texture { ScopeMetalView(frame: texture, gradient: gradient) }
                Canvas { context, size in
                    for hue in OKLabVertexWarp.vertexHues[space]!.enumerated().filter { $0.offset != 1 }.map(\.element) {
                        var guide = Path()
                        let x = size.width * hue.truncatingRemainder(dividingBy: 2 * .pi) / (2 * .pi)
                        guide.move(to: CGPoint(x: x,y: 0))
                        guide.addLine(to: CGPoint(x: x,y: size.height))
                        context.stroke(guide, with: .color(EditorGraphStyle.guideColor), style: EditorGraphStyle.guide)
                    }
                    func outline(_ multiplier: Double, color: Color) {
                        guard boundary.count == 360 else { return }
                        var path = Path()
                        for i in 0...360 {
                            let y = size.height*(1-boundary[i%360]*multiplier/maximum)
                            let p = CGPoint(x: size.width*Double(i)/360,y: y)
                            if i == 0 { path.move(to:p) } else { path.addLine(to:p) }
                        }
                        context.stroke(path, with: .color(color), style: EditorGraphStyle.guide)
                    }
                    if !monochrome { outline(scale, color: EditorGraphStyle.guideColor) }
                    else {
                        for value in [0.0,0.5,1.0] {
                            context.draw(Text(value,format:.number.precision(.fractionLength(1))).font(.caption2).foregroundStyle(.secondary),
                                at:CGPoint(x:12,y:max(8,min(size.height-8,(1-value)*size.height))))
                        }
                    }
                }.allowsHitTesting(false)
                marker(lightness: monochrome)
                MountainRangeHandles(controls:$controls,selected:$selected,space:space,maximumChroma:maximum,scale:scale,boundary:boundary,movementEnabled:!monochrome,densityMode:monochrome).filmLock(.vertices)
            }.aspectRatio(1.6, contentMode: .fit)
            Canvas { context, size in
                for i in 0..<180 {
                    let angle = Double(i)/180 * 2 * Double.pi
                    let rgb = OKLabColor.linear(SIMD3(0.7, 0.14*cos(angle), 0.14*sin(angle)), space: .sRGB)
                    let color = Color(.sRGBLinear, red: min(1,max(0,rgb.x)),
                                      green: min(1,max(0,rgb.y)), blue: min(1,max(0,rgb.z)))
                    context.fill(Path(CGRect(x: Double(i)/180*size.width, y: 0,
                                             width: size.width/180+1, height: size.height)),
                                 with: .color(color))
                }
            }
            .frame(height: 5)
            .accessibilityLabel("Hue")
            HStack {
                Text(space.rawValue)
                Spacer()
                Text(hdr ? "HDR" : "SDR").foregroundStyle(.secondary)
            }.font(.caption)
            HStack {
                Toggle("Monochrome", isOn: Binding(get: { monochrome }, set: { enabled in
                    monochrome = enabled
                    OKLabVertexWarp.setMonochrome(enabled, controls: &controls)
                })).toggleStyle(.switch).filmLock(.vertices)
                Spacer()
                Button("Reset") {
                    controls = defaults.vertexWarp
                    if monochrome { OKLabVertexWarp.setMonochrome(true, controls: &controls) }
                }
            }
            .filmLock(.vertices)
            Group {
            if let i=selected {
                HStack {
                    Text(LocalizedStringKey(MountainRangeHandles.names[i])).foregroundStyle(MountainRangeHandles.colors[i])
                    Spacer()
                }
                HStack {
                    if !monochrome {
                        Text("Chroma")
                        AdjustmentField(title:"Chroma",value:$controls[i].chroma,range:0...2,unit:"×",width:52)
                    }
                    Spacer()
                    Text("Density")
                    AdjustmentField(title:"Density",value:$controls[i].lightness,range: -0.25...0.25,digits:3,width:52)
                }
                if !monochrome {
                    EditorSlider(value: $controls[i].lightness, in: -0.25...0.25) {
                        Text("Density")
                    }.controlReset { controls[i].lightness = defaults.vertexWarp[i].lightness }.labelsHidden()
                }
            }
            }.filmLock(.vertices)
            if showsTwister {
                Divider()
                LightnessHueControls(controls:$controls,selected:$selected,space:space,texture:lightnessTexture,hover: marker(lightness: true),gradient:gradient).filmLock(.hueTwister)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(12)
        .help(monochrome
            ? "Source pixel density by OKLCH hue and lightness. Drag color nodes vertically to adjust Density."
            : "Pixel density by OKLCH hue and chroma. Outlines show the selected gamut’s maximum chroma across all lightness values. Neutral pixels have no hue and are omitted.")
        .task(id: space) { boundary = await HueChromaBoundary.shared.values(space) }
        .task(id: Request(revision: revision, space: space, maximum: maximum, hdr: hdr, hasSource: source != nil, showHueTwister: showsTwister, monochrome: monochrome)) {
            guard let source else { texture = nil; lightnessTexture = nil; return }
            do {
                if worker == nil { worker = try GPUVectorscope() }
                let result = try await worker!.render(source: source, mapping: ToneMapping(),
                    space: space, zoom: -1/maximum, hueChroma: true, lightnessScale: monochrome ? 1 : 0)
                try Task.checkCancellation()
                texture = result
                if showsTwister {
                    let lighter = try await worker!.render(source:source,mapping:ToneMapping(),
                        space:space,zoom:-1/maximum,hueChroma:true,lightnessScale:scale)
                    try Task.checkCancellation()
                    lightnessTexture = lighter
                } else { lightnessTexture = nil }
                error = nil
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription }
        }
    }
}
