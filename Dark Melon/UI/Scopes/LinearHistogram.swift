import SwiftUI

struct LinearHistogram: View {
    var sourceOnly = false
    let development: RAWDevelopment?
    let histogram: HistogramData?
    let histogramError: String?
    @Binding var binCount: Int
    @Binding var mapping: ToneMapping
    let sdrSource: CGImage?
    let revision: UUID
    let colorSpace: ProcessingColorSpace
    let hdrPreview: Bool
    @Binding var showingSDR: Bool
    let hoverTransform: TransformSettings?
    var onWhitePointEditingChanged: (Bool) -> Void = { _ in }
    @State private var sdrHistogram: HistogramData?
    @State private var sdrError: String?
    @State private var sdrWorker: GPUHistogram?
    @State private var workerSpace: ProcessingColorSpace?
    @State private var draggingInputMaximum: Double?
    @State private var zoomHistogram: HistogramData?
    @State private var zoomWorker: GPUHistogram?
    @State private var zoomSpace: ProcessingColorSpace?
    @State private var completedZoomRequest: HistogramZoomRequest?
    private var inputMaximum: Double {
        draggingInputMaximum ?? HistogramInputRange.maximum(white: mapping.white, hdr: hdrPreview, encoded: showingSDR, sourceMaximum: mapping.sourceMaximum)
    }
    private var zoomRequest: HistogramZoomRequest {
        HistogramZoomRequest(sourceID: development?.id, bins: binCount, upper: inputMaximum, space: colorSpace)
    }
    private var usingZoomHistogram: Bool {
        !showingSDR && inputMaximum < mapping.sourceMaximum && completedZoomRequest == zoomRequest
    }
    private var displayedHistogram: HistogramData? {
        showingSDR ? sdrHistogram : usingZoomHistogram ? zoomHistogram : histogram
    }
    private var histogramMaximum: Double { usingZoomHistogram ? inputMaximum : (showingSDR ? 1 : mapping.sourceMaximum) }

    private let colors: [Color] = [.red, .green, .blue]

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button(showingSDR ? "SDR RGB" : "Linear RGB") { showingSDR.toggle() }
                    .disabled(sourceOnly)
                    .fontWeight(.medium)
                    .help("Toggle the linear source histogram and the developed SDR preview histogram. Black and white points can only be adjusted in Linear RGB.")
                Spacer()
            }
            HStack {
                if !showingSDR {
                    Text("Curve: SDR").foregroundStyle(.mint)
                    Text("HDR").foregroundStyle(.orange)
                }
                Spacer()
                if let development {
                    Text("\(development.width) × \(development.height)")
                        .foregroundStyle(.secondary)
                }
            }
            Canvas { context, size in
                for tick in 0...4 {
                    let x = size.width * CGFloat(tick) / 4
                    var grid = Path()
                    grid.move(to: CGPoint(x: x, y: 0))
                    grid.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(grid, with: .color(.white.opacity(0.12)), lineWidth: 1)
                }
                guard let histogram = displayedHistogram else { return }
                let channels = histogram.histogram
                let count = channels[0].count
                let visibleCount = max(1, min(count, Int(ceil(Double(count) * inputMaximum / histogramMaximum))))
                let scalingCounts = showingSDR
                    ? channels.flatMap { Array($0[3...252]) }
                    : channels.flatMap { Array($0.prefix(visibleCount)) }
                let peak = max(1, scalingCounts.max() ?? 1)
                let logPeak = log1p(Double(peak))
                context.blendMode = .plusLighter
                for channel in 0..<3 {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: size.height))
                    for index in 0..<visibleCount {
                        let x0 = CGFloat(index) / CGFloat(count) * size.width * histogramMaximum / inputMaximum
                        let x1 = CGFloat(index + 1) / CGFloat(count) * size.width * histogramMaximum / inputMaximum
                        let value = Double(channels[channel][index])
                        let height = showingSDR ? min(1, value / Double(peak)) : log1p(value) / logPeak
                        let y = size.height * (1 - CGFloat(height))
                        path.addLine(to: CGPoint(x: x0, y: y))
                        path.addLine(to: CGPoint(x: x1, y: y))
                    }
                    path.addLine(to: CGPoint(x: size.width, y: size.height))
                    path.closeSubpath()
                    context.fill(path, with: .color((mapping.color.monochrome ? Color.white : colors[channel]).opacity(0.45)))
                    context.stroke(path, with: .color((mapping.color.monochrome ? Color.white : colors[channel]).opacity(0.85)), lineWidth: 0.75)
                }
            }
            .clipped()
            .overlay {
                if !sourceOnly && !showingSDR { HistogramToneCurve(mapping: mapping, hdrPreview: hdrPreview, inputMaximum: inputMaximum).allowsHitTesting(false) }
            }
            .overlay {
                HoverPixelOverlay(source: showingSDR ? sdrSource : development?.preview,
                    revision: showingSDR ? revision : development?.id, space: colorSpace,
                    encoded: showingSDR, transform: hoverTransform) { context, size, rgb in
                    let weights = colorSpace.luminance
                    let value = rgb.x * weights.x + rgb.y * weights.y + rgb.z * weights.z
                    let x = min(size.width - 1, max(1, min(1, max(0, value / inputMaximum)) * size.width))
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: 0))
                    line.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(line, with: .color(.black.opacity(0.9)), lineWidth: 3)
                    context.stroke(line, with: .color(.white),
                                   style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    let label = Text("Y" + (value < 0 ? "‹" : value > inputMaximum ? "›" : ""))
                        .font(.caption2.bold())
                    let point = CGPoint(x: min(size.width - 12, max(12, x)), y: 9)
                    context.draw(label.foregroundStyle(.black), at: CGPoint(x: point.x + 1, y: point.y + 1))
                    context.draw(label.foregroundStyle(.white), at: point)
                }
                .allowsHitTesting(false)
            }
            .overlay {
                if !sourceOnly && !showingSDR { HistogramPoints(mapping: $mapping, inputMaximum: inputMaximum, onWhitePointEditingChanged: { editing in
                    // Freeze the axis during a drag so zoom cannot feed back into picking.
                    if editing { draggingInputMaximum = inputMaximum }
                    else { draggingInputMaximum = nil }
                    onWhitePointEditingChanged(editing)
                }).filmLock(.whitePoint) }
            }
            .frame(height: 190)
            .onGeometryChange(for: Int.self) { geometry in
                max(1, Int(geometry.size.width.rounded(.down)))
            } action: { binCount = $0 }
            HStack {
                ForEach(0...4, id: \.self) { tick in
                    if showingSDR { Text("\(Int((Double(tick) * 255 / 4).rounded()))") }
                    else { Text(Double(tick) / 4 * inputMaximum, format: .number.precision(.fractionLength(inputMaximum < 0.01 ? 4 : inputMaximum < 0.1 ? 3 : 2))) }
                    if tick < 4 { Spacer() }
                }
            }
            .foregroundStyle(.secondary)
            if let error = showingSDR ? sdrError : histogramError {
                Text("Histogram unavailable: \(error)").foregroundStyle(.secondary)
            } else if displayedHistogram == nil, development != nil {
                ProgressView().controlSize(.small)
            }
        }
        .font(.caption.monospacedDigit())
        .padding(16)
        .modifier(ShellSection())
        .task(id: zoomRequest) {
            let request = zoomRequest
            guard request.upper < mapping.sourceMaximum, !showingSDR, let source = development?.preview, let id = request.sourceID else { return }
            do {
                if zoomWorker == nil || zoomSpace != colorSpace {
                    zoomWorker = try GPUHistogram(colorSpace: colorSpace)
                    zoomSpace = colorSpace
                }
                let result = try await zoomWorker!.calculate(image: CIImage(cgImage: source), sourceID: id,
                                                            bins: request.bins, upperInput: request.upper)
                try Task.checkCancellation()
                zoomHistogram = result
                completedZoomRequest = request
            } catch { /* Keep the existing source histogram if the zoom pass is unavailable. */ }
        }
        .task(id: SDRHistogramRequest(revision: revision, bins: 256, space: colorSpace)) {
            guard let sdrSource else { sdrHistogram = nil; return }
            do {
                if sdrWorker == nil || workerSpace != colorSpace {
                    sdrWorker = try GPUHistogram(colorSpace: colorSpace, encoded: true)
                    workerSpace = colorSpace
                }
                let result = try await sdrWorker!.calculate(image: CIImage(cgImage: sdrSource),
                                                           sourceID: revision, bins: 256)
                try Task.checkCancellation()
                sdrHistogram = result
                sdrError = nil
            } catch is CancellationError {
            } catch { sdrError = error.localizedDescription }
        }
    }
}


private struct SDRHistogramRequest: Equatable {
    let revision: UUID
    let bins: Int
    let space: ProcessingColorSpace
}

private struct HistogramZoomRequest: Equatable {
    let sourceID: UUID?
    let bins: Int
    let upper: Double
    let space: ProcessingColorSpace
}
