import SwiftUI
import UniformTypeIdentifiers
import ImageIO

nonisolated enum ExportFormat: String, Codable, CaseIterable, Identifiable {
    case jpeg = "JPEG", tiff = "TIFF", heif = "HEIF"
    var id: Self { self }
    var type: UTType {
        switch self { case .jpeg: .jpeg; case .tiff: .tiff; case .heif: .heic }
    }
    var fileExtension: String {
        switch self { case .jpeg: "jpg"; case .tiff: "tif"; case .heif: "heic" }
    }
}

nonisolated enum HEIFHDRMode: String, Codable, CaseIterable, Identifiable {
    case off = "Off"
    case gainMap = "Gain map"
    case direct = "Direct HDR" // Keep the persisted value compatible with existing preferences.
    var id: Self { self }
    var label: LocalizedStringKey {
        switch self {
        case .off: "Off"
        case .gainMap: "Gain map"
        case .direct: "PQ HDR"
        }
    }
}

nonisolated struct HEIFSettings: Codable, Equatable, Sendable {
    var format = ExportFormat.heif
    var heifHDRMode = HEIFHDRMode.gainMap
    var jpegHDR = false
    var tiffHDR = false
    var tiff16Bit = true
    var scale = 1.0
    var quality = 0.9
    var rgbGainMap = true
    var halfSizeGainMap = true
    // Freeze the app preference with the export settings, including queued jobs.
    var effectiveISO = ExportMetadata.effectiveISOEnabled

    init() {}
    private enum CodingKeys: String, CodingKey {
        case format, heifHDRMode, jpegHDR, tiffHDR, tiff16Bit, scale, quality, rgbGainMap, halfSizeGainMap, effectiveISO
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        format = try values.decodeIfPresent(ExportFormat.self, forKey: .format) ?? .heif
        heifHDRMode = try values.decodeIfPresent(HEIFHDRMode.self, forKey: .heifHDRMode) ?? .gainMap
        jpegHDR = try values.decodeIfPresent(Bool.self, forKey: .jpegHDR) ?? false
        tiffHDR = try values.decodeIfPresent(Bool.self, forKey: .tiffHDR) ?? false
        tiff16Bit = try values.decodeIfPresent(Bool.self, forKey: .tiff16Bit) ?? true
        scale = try values.decodeIfPresent(Double.self, forKey: .scale) ?? 1
        quality = try values.decodeIfPresent(Double.self, forKey: .quality) ?? 0.9
        rgbGainMap = try values.decodeIfPresent(Bool.self, forKey: .rgbGainMap) ?? true
        halfSizeGainMap = try values.decodeIfPresent(Bool.self, forKey: .halfSizeGainMap) ?? true
        effectiveISO = try values.decodeIfPresent(Bool.self, forKey: .effectiveISO) ?? ExportMetadata.effectiveISOEnabled
    }

    private static let defaultsKey = "heifExportSettings.v1"

    static func restored() -> Self {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              var settings = try? JSONDecoder().decode(Self.self, from: data),
              settings.scale.isFinite, settings.quality.isFinite else { return Self() }
        settings.effectiveISO = ExportMetadata.effectiveISOEnabled
        settings.scale = min(1, max(0.000001, settings.scale))
        settings.quality = min(1, max(0, settings.quality))
        return settings
    }

    func remember() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}

nonisolated enum HEIFExportError: LocalizedError {
    case encoding, gainMap
    var errorDescription: String? {
        switch self {
        case .encoding: String(localized: "The image encoder could not save this image.")
        case .gainMap: String(localized: "The encoder could not create an ISO HDR gain map for this SDR/HDR pair.")
        }
    }
}

struct HEIFDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.heic, .jpeg, .tiff] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct HEIFExportOptions: View {
    @Binding var settings: HEIFSettings
    let width: Int
    let height: Int
    let hdrEnabled: Bool
    let sourceURL: URL
    let mapping: ToneMapping
    let colorSpace: ProcessingColorSpace
    let rawSettings: RAWSettings
    var percentageOnly = false
    var variationGrid: Binding<Int>? = nil
    let save: (RAWDeveloper) -> Void
    @AppStorage(ExportMetadata.effectiveISOPreferenceKey) private var effectiveISO = true
    @Environment(\.dismiss) private var dismiss
    @State private var widthText = ""
    @State private var heightText = ""
    @State private var encodedBytes: Int?
    @State private var worker: RAWDeveloper?
    @State private var measuredSettings: HEIFSettings?
    @State private var sizeError: String?
    @FocusState private var editingDimension: Dimension?
    private enum Dimension: Hashable { case width, height }
    private var outputHDREnabled: Bool {
        if variationGrid != nil { return false }
        if percentageOnly { return hdrEnabled } // A batch can contain both HDR and log-LUT SDR outputs.
        guard hdrEnabled else { return false }
        guard let id = mapping.lutID, LUTStore.shared.configuration(for: id).input.isLog,
              LUTStore.shared.cube(for: id) != nil else { return true }
        return false
    }
    private var baseSize: CGSize { mapping.transform?.resolution(width: width, height: height, estimate: .maximum) ?? CGSize(width: width, height: height) }
    private var outputWidth: Int { max(1, Int((Double(baseSize.width) * settings.scale).rounded())) }
    private var outputHeight: Int { max(1, Int((Double(baseSize.height) * settings.scale).rounded())) }

    private func sessionWorker() -> RAWDeveloper {
        if let worker { return worker }
        let created = RAWDeveloper(colorSpace: colorSpace, rawSettings: rawSettings, exporting: true, memoryLimitMB: BatchExportBudget.singleFileMegabytes)
        worker = created
        return created
    }

    private func syncDimensions() {
        if editingDimension != .width { widthText = String(outputWidth) }
        if editingDimension != .height { heightText = String(outputHeight) }
    }
    private func updateDimension(_ text: String, dimension: Dimension) {
        guard editingDimension == dimension, let pixels = Int(text), pixels > 0 else { return }
        let original = Int(dimension == .width ? baseSize.width : baseSize.height)
        guard pixels <= original else { return }
        settings.scale = Double(pixels) / Double(max(1, original))
        syncDimensions()
    }
    private func commitDimension(_ dimension: Dimension?) {
        guard let dimension else { return }
        let original = Int(dimension == .width ? baseSize.width : baseSize.height)
        let text = dimension == .width ? widthText : heightText
        let current = dimension == .width ? outputWidth : outputHeight
        if let pixels = Int(text), pixels != current {
            settings.scale = Double(min(original, max(1, pixels))) / Double(max(1, original))
        }
        widthText = String(outputWidth)
        heightText = String(outputHeight)
    }

    private func finishDimensionEditing() {
        commitDimension(editingDimension)
        editingDimension = nil
    }

    private func useSliderScale(_ scale: Double) {
        // The slider becomes authoritative. Refresh both drafts before focus-loss
        // callbacks can commit the previously selected field over this value.
        editingDimension = nil
        settings.scale = (scale * 20).rounded() / 20
        widthText = String(outputWidth)
        heightText = String(outputHeight)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Format", selection: $settings.format) {
                    ForEach(ExportFormat.allCases) { format in
                        Text(format.rawValue).tag(format)
                    }
                }
                .pickerStyle(.segmented)
                .padding()
                options(for: settings.format)
            }
            .navigationTitle(variationGrid == nil ? "Export Image" : "Variation Export")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save…") {
                        finishDimensionEditing()
                        let worker = sessionWorker()
                        dismiss()
                        save(worker)
                    }
                    .disabled(variationGrid.map { outputWidth < $0.wrappedValue || outputHeight < $0.wrappedValue } ?? false)
                }
            }
        }
        .onAppear { settings.effectiveISO = effectiveISO; syncDimensions() }
        .onChange(of: effectiveISO) { _, value in settings.effectiveISO = value }
        .onChange(of: settings.scale) { _, _ in syncDimensions() }
        .onChange(of: editingDimension) { previous, _ in commitDimension(previous) }
        .task {
            guard variationGrid == nil else { return }
            // This session retains developed buffers and the last encoded file.
            // Save receives the same worker, including an encode still in flight.
            let worker = sessionWorker()
            var attempted: HEIFSettings?
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
                let snapshot = settings
                guard snapshot.format != .tiff, snapshot != attempted else { continue }
                attempted = snapshot
                do {
                    let count = try await worker.encodedSize(sourceURL, mapping: mapping, settings: snapshot)
                    try Task.checkCancellation()
                    guard settings == snapshot else { continue }
                    encodedBytes = count
                    measuredSettings = snapshot
                    sizeError = nil
                } catch is CancellationError { return }
                catch {
                    guard settings == snapshot else { continue }
                    sizeError = error.localizedDescription
                    encodedBytes = nil
                    measuredSettings = snapshot
                }
            }
        }
        #if os(macOS)
        .frame(width: 460, height: variationGrid == nil ? 460 : 540)
        #endif
    }

    private func options(for format: ExportFormat) -> some View {
        Form {
            if let variationGrid {
                Picker("Grid size", selection: variationGrid) {
                    ForEach(2...8, id: \.self) { size in Text("\(size) × \(size)").tag(size) }
                }
                Text("One SDR image. Each tile gets a fresh Brew at the current strength.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Tile size", value: "\(outputWidth / max(2, variationGrid.wrappedValue)) × \(outputHeight / max(2, variationGrid.wrappedValue)) px")
            }
            LabeledContent("Linear size", value: settings.scale.formatted(.percent.precision(.fractionLength(0))))
            EditorSlider(value: Binding(get: { min(1, max(0.25, (settings.scale * 20).rounded() / 20)) },
                                  set: { useSliderScale($0) }),
                   in: 0.25...1, step: 0.05) { Text("Linear size") }
                onEditingChanged: { editing in
                    if editing { finishDimensionEditing() }
                }
            .controlReset { useSliderScale(HEIFSettings().scale) }
            if percentageOnly {
                LabeledContent("First image", value: "\(outputWidth) × \(outputHeight) px")
                    .monospacedDigit().foregroundStyle(.secondary)
            } else {
            HStack {
                TextField("Width", text: Binding(get: { widthText }, set: {
                    widthText = $0; updateDimension($0, dimension: .width)
                }))
                    .focused($editingDimension, equals: .width)
                    .onSubmit { finishDimensionEditing() }
                    .accessibilityLabel("Export width in pixels")
                Text("×").foregroundStyle(.secondary)
                TextField("Height", text: Binding(get: { heightText }, set: {
                    heightText = $0; updateDimension($0, dimension: .height)
                }))
                    .focused($editingDimension, equals: .height)
                    .onSubmit { finishDimensionEditing() }
                    .accessibilityLabel("Export height in pixels")
                Text("px").foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("\(Double(outputWidth) * Double(outputHeight) / 1_000_000, format: .number.precision(.fractionLength(2))) MP")
                    .foregroundStyle(.secondary).fixedSize()
            }
            .textFieldStyle(.roundedBorder)
            .monospacedDigit()
            }
            if format != .tiff {
                LabeledContent("Quality", value: settings.quality.formatted(.percent.precision(.fractionLength(0))))
                EditorSlider(value: $settings.quality, in: 0...1, step: 0.01, label: { Text("Quality") }).controlReset { settings.quality = HEIFSettings().quality }
                if variationGrid == nil {
                LabeledContent("Encoded size") {
                    if measuredSettings == settings, let encodedBytes {
                        Text(Int64(encodedBytes), format: .byteCount(style: .file))
                    } else if measuredSettings == settings, sizeError != nil {
                        Text("Unavailable").help(sizeError ?? "")
                    } else {
                        Text("Calculating…")
                    }
                }
                .foregroundStyle(.secondary)
                }
            }
            if format == .tiff {
                if outputHDREnabled {
                    Picker("Version", selection: $settings.tiffHDR) {
                        Text("SDR").tag(false)
                        Text("HDR").tag(true)
                    }.pickerStyle(.segmented)
                }
                Picker("Bit depth", selection: $settings.tiff16Bit) {
                    Text("8 bit").tag(false)
                    Text("16 bit").tag(true)
                }.pickerStyle(.segmented)
                Text(outputHDREnabled
                     ? "LZW compression. HDR preserves the full rendition by scaling it down by HDR Gain to fit a standard SDR file."
                     : "LZW compression.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if outputHDREnabled && format == .heif {
                Picker("HDR encoding", selection: $settings.heifHDRMode) {
                    ForEach(HEIFHDRMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }.pickerStyle(.segmented)
                if settings.heifHDRMode == .direct {
                    Text("10-bit PQ HDR without a gain map. SDR appearance is determined by the viewer.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if outputHDREnabled && format == .jpeg {
                Toggle("HDR gain map", isOn: $settings.jpegHDR)
                    .help("Save an SDR JPEG with an ISO HDR gain map for compatible viewers.")
            }
            if outputHDREnabled && ((format == .heif && settings.heifHDRMode == .gainMap) || (format == .jpeg && settings.jpegHDR)) {
                Toggle("RGB gain map", isOn: $settings.rgbGainMap)
                Text(settings.rgbGainMap ? "Color gain map" : "Monochrome gain map")
                    .foregroundStyle(.secondary)
                Toggle("Half-size gain map", isOn: $settings.halfSizeGainMap)
                Text("Half the exported width and height; one quarter as many gain-map pixels.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// Image I/O's ISO gain-map metadata representation. Gains are log2 ratios
// between linear SDR/HDR values, using the same offsets for encode and decode.
nonisolated enum HEIFGainMetadata {
    static func make(minimum: Double, maximum: Double, headroom: Double, rgb: Bool) throws -> CGImageMetadata {
        let channel = """
        <rdf:li rdf:parseType="Resource">
        <HDRToneMap:GainMapMin>\(minimum)</HDRToneMap:GainMapMin>
        <HDRToneMap:GainMapMax>\(maximum)</HDRToneMap:GainMapMax>
        <HDRToneMap:Gamma>1</HDRToneMap:Gamma>
        <HDRToneMap:BaseOffset>0.00001</HDRToneMap:BaseOffset>
        <HDRToneMap:AlternateOffset>0.00001</HDRToneMap:AlternateOffset>
        </rdf:li>
        """
        let xmp = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:HDRToneMap="http://ns.apple.com/HDRToneMap/1.0/">
        <HDRToneMap:Version>1</HDRToneMap:Version>
        <HDRToneMap:BaseHeadroom>0</HDRToneMap:BaseHeadroom>
        <HDRToneMap:AlternateHeadroom>\(log2(headroom))</HDRToneMap:AlternateHeadroom>
        <HDRToneMap:ChannelMetadata><rdf:Seq>
        \(Array(repeating: channel, count: rgb ? 3 : 1).joined())
        </rdf:Seq></HDRToneMap:ChannelMetadata>
        <HDRToneMap:BaseColorIsWorkingColor>True</HDRToneMap:BaseColorIsWorkingColor>
        </rdf:Description></rdf:RDF></x:xmpmeta>
        """
        guard let metadata = CGImageMetadataCreateFromXMPData(Data(xmp.utf8) as CFData) else {
            throw HEIFExportError.gainMap
        }
        return metadata
    }
}
