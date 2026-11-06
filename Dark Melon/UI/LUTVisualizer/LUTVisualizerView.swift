#if os(macOS)
import SwiftUI
import SceneKit

struct LUTVisualizerView: View {
    let model: LUTVisualizerModel
    var save: () -> Void

    var body: some View {
        NavigationSplitView {
            LUTVisualizerInspector(model: model)
                .navigationSplitViewColumnWidth(min: 250, ideal: 285, max: 340)
        } detail: {
            LUTVisualizerCanvas(model: model)
                .navigationTitle("LUT Visualizer")
                .toolbar {
                    ToolbarItemGroup {
                        LUTExportControl(model: model, save: save)
                        Button { model.resetZoomAndPan() } label: { Label("Reset Zoom and Pan", systemImage: "viewfinder") }
                            .help("Reset zoom and pan, preserving rotation")
                        LUTAutoRotateControl(model: model)
                    }
                }
        }
        .alert("LUT Visualizer", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .frame(minWidth: 800, minHeight: 620)
    }
}

private struct LUTExportControl: View {
    let model: LUTVisualizerModel
    let save: () -> Void

    var body: some View {
        Button("Export LUT…", systemImage: "square.and.arrow.up", action: save)
            .disabled(model.lut == nil || model.updating || model.saving || model.error != nil)
    }
}

private struct LUTAutoRotateControl: View {
    @Bindable var model: LUTVisualizerModel

    var body: some View {
        Toggle(isOn: $model.settings.autoRotate) {
            Label("Auto Rotate", systemImage: "rotate.3d")
        }
        .accessibilityLabel("Auto Rotate")
        .help("Auto rotate")
    }
}

private struct LUTVisualizerCanvas: View {
    @Environment(\.displayScale) private var displayScale
    let model: LUTVisualizerModel

    var body: some View {
        LUTSceneView(model: model)
            .onGeometryChange(for: ViewportMetrics.self) {
                ViewportMetrics(size: $0.size, scale: displayScale)
            } action: { metrics in
                model.updateViewport(metrics.size, scale: metrics.scale)
            }
            .accessibilityLabel("Interactive RGB LUT cube. Drag to rotate; scroll or pinch to zoom.")
            .overlay(alignment: .bottom) { LUTVisualizerOverlay(model: model) }
    }
}

private struct LUTVisualizerOverlay: View {
    let model: LUTVisualizerModel

    var body: some View {
        VStack(spacing: 12) {
            if model.settings.showRamp { RampView(model: model) }
            HStack {
                Text("\(model.pointCount.formatted()) points")
                if model.settings.clipping != .off {
                    Text(model.settings.clipping == .unclipped
                         ? "· \(model.clippedCount.formatted()) clipped hidden"
                         : "· \(model.clippedCount.formatted()) at limits")
                }
                Spacer()
                Text("Drag to rotate · Scroll to zoom")
            }
            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            .padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }.padding(16)
    }
}

private struct LUTVisualizerInspector: View {
    @Bindable var model: LUTVisualizerModel

    private var densityLevel: Binding<Double> {
        Binding {
            Double(LUTViewerSettings.densityLevels.firstIndex(of: model.settings.density) ?? 0)
        } set: { level in
            let levels = LUTViewerSettings.densityLevels
            let index = min(levels.count - 1, max(0, Int(level.rounded())))
            model.settings.density = levels[index]
        }
    }

    var body: some View {
        Form {
            Section("Visualization") {
                Picker("Mode", selection: $model.settings.mode) {
                    ForEach(LUTViewerSettings.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
                if model.settings.mode == .slice {
                    Picker("Slice axis", selection: $model.settings.axis) {
                        Text("R").tag(0); Text("G").tag(1); Text("B").tag(2)
                    }.pickerStyle(.segmented)
                    slider("Position", value: $model.settings.slice)
                }
                VStack(alignment: .leading) {
                    HStack { Text("Point Density"); Spacer(); Text("\(Int(model.settings.density))³").foregroundStyle(.secondary) }
                    Slider(value: densityLevel, in: 0...Double(LUTViewerSettings.densityLevels.count - 1), step: 1)
                        .accessibilityLabel("Point density")
                        .accessibilityValue(Text("\(Int(model.settings.density))³"))
                }
                slider("Point Size (%)", value: $model.settings.pointSize, range: 0.3...1)
                    .help("Point size as a percentage of the viewport’s shorter edge")
                slider("Point Opacity", value: $model.settings.opacity)
                Toggle("Show Vectors", isOn: $model.settings.vectors)
                Toggle("Show Ramp", isOn: $model.settings.showRamp)
                slider("Background", value: $model.settings.background)
            }
            Section("Analysis") {
                Picker("Color Region", selection: $model.settings.region) {
                    ForEach(["All", "R", "G", "B", "C", "M", "Y"], id: \.self) { Text($0) }
                }
                Toggle("Neutrals Only", isOn: $model.settings.neutrals)
                VStack(alignment: .leading) {
                    Text("Show Clipping")
                    Picker("Show Clipping", selection: $model.settings.clipping) {
                        ForEach(LUTViewerSettings.Clipping.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden()
                }
                if model.settings.clipping == .unclipped {
                    Text("Shows only points that are not clipped, with their original colors.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if model.settings.clipping == .highlight {
                    Text("Highlights channels reaching 0 or 1 from an interior input, or exceeding that range. Other points are dimmed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Text("Live SDR export · sRGB input and output\nInput is normalized from black to the white point over 0–1. Point density also sets the exported LUT size. RAW decoding and spatial effects are excluded.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Inspector")
    }

    private func slider<V: BinaryFloatingPoint>(_ title: String, value: Binding<V>, range: ClosedRange<V> = 0...1) -> some View where V.Stride: BinaryFloatingPoint {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(Double(value.wrappedValue), format: .number.precision(.fractionLength(2)))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range).accessibilityLabel(title)
        }
    }
}

nonisolated private struct ViewportMetrics: Equatable, Sendable {
    let size: CGSize
    let scale: CGFloat
}

private struct RampView: View {
    let model: LUTVisualizerModel
    var body: some View {
        let steps = 128
        let lut = model.lut
        let samples = (0..<steps).map { index in
            let input = SIMD3<Float>(repeating: Float(index) / Float(steps - 1))
            return lut?.sample(input) ?? input
        }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Neutral ramp").font(.caption.weight(.medium))
                Spacer()
                Text("Input → RGB output").font(.caption).foregroundStyle(.secondary)
            }
            Canvas { context, size in
                for i in 0..<steps {
                    let c = samples[i]
                    let color = Color(red: Double(max(0, min(1, c.x))), green: Double(max(0, min(1, c.y))), blue: Double(max(0, min(1, c.z))))
                    context.fill(Path(CGRect(x: Double(i) * size.width / Double(steps), y: 0,
                                             width: size.width / Double(steps) + 0.5, height: 14)), with: .color(color))
                }
                let top: CGFloat = 24
                let height = size.height - top - 4
                for grid in 0...4 {
                    let y = top + height * CGFloat(grid) / 4
                    var line = Path(); line.move(to: CGPoint(x: 0, y: y)); line.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(line, with: .color(.secondary.opacity(0.2)), lineWidth: 0.5)
                }
                var identity = Path()
                identity.move(to: CGPoint(x: 0, y: top + height))
                identity.addLine(to: CGPoint(x: size.width, y: top))
                context.stroke(identity, with: .color(.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                for channel in 0..<3 {
                    var path = Path()
                    for i in 0..<steps {
                        let t = Float(i) / Float(steps - 1)
                        let c = samples[i][channel]
                        let point = CGPoint(x: CGFloat(t) * size.width, y: top + (1 - CGFloat(max(0, min(1, c)))) * height)
                        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                    context.stroke(path, with: .color([Color.red, .green, .blue][channel].opacity(0.85)), lineWidth: 1.5)
                }
            }.frame(height: 96)
            HStack {
                Text("0"); Spacer(); Text("1 · White point")
            }.font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Neutral input ramp and red, green, blue output curves")
    }
}

#endif
