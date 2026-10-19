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

nonisolated struct HEIFSettings: Codable, Equatable, Sendable {
    var format = ExportFormat.heif
    var jpegHDR = false
    var tiffHDR = false
    var tiff16Bit = true
    var scale = 1.0
    var quality = 0.9
    var rgbGainMap = true
    var halfSizeGainMap = true

    init() {}
    private enum CodingKeys: String, CodingKey {
        case format, jpegHDR, tiffHDR, tiff16Bit, scale, quality, rgbGainMap, halfSizeGainMap
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        format = try values.decodeIfPresent(ExportFormat.self, forKey: .format) ?? .heif
        jpegHDR = try values.decodeIfPresent(Bool.self, forKey: .jpegHDR) ?? false
        tiffHDR = try values.decodeIfPresent(Bool.self, forKey: .tiffHDR) ?? false
        tiff16Bit = try values.decodeIfPresent(Bool.self, forKey: .tiff16Bit) ?? true
        scale = try values.decodeIfPresent(Double.self, forKey: .scale) ?? 1
        quality = try values.decodeIfPresent(Double.self, forKey: .quality) ?? 0.9
        rgbGainMap = try values.decodeIfPresent(Bool.self, forKey: .rgbGainMap) ?? true
        halfSizeGainMap = try values.decodeIfPresent(Bool.self, forKey: .halfSizeGainMap) ?? true
    }

    private static let defaultsKey = "heifExportSettings.v1"

    static func restored() -> Self {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              var settings = try? JSONDecoder().decode(Self.self, from: data),
              settings.scale.isFinite, settings.quality.isFinite else { return Self() }
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
        case .encoding: "The image encoder could not save this image."
        case .gainMap: "The encoder could not create an ISO HDR gain map for this SDR/HDR pair."
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
    let save: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var widthText = ""
    @State private var heightText = ""
    @State private var encodedBytes: Int?
    @State private var measuredSettings: HEIFSettings?
    @State private var sizeError: String?
    @FocusState private var editingDimension: Dimension?
    private enum Dimension: Hashable { case width, height }
    private var outputWidth: Int { max(1, Int((Double(width) * settings.scale).rounded())) }
    private var outputHeight: Int { max(1, Int((Double(height) * settings.scale).rounded())) }

    private func syncDimensions() {
        if editingDimension != .width { widthText = String(outputWidth) }
        if editingDimension != .height { heightText = String(outputHeight) }
    }
    private func updateDimension(_ text: String, dimension: Dimension) {
        guard editingDimension == dimension, let pixels = Int(text), pixels > 0 else { return }
        let original = dimension == .width ? width : height
        guard pixels <= original else { return }
        settings.scale = Double(pixels) / Double(max(1, original))
        syncDimensions()
    }
    private func commitDimension(_ dimension: Dimension?) {
        guard let dimension else { return }
        let original = dimension == .width ? width : height
        let text = dimension == .width ? widthText : heightText
        let current = dimension == .width ? outputWidth : outputHeight
        if let pixels = Int(text), pixels != current {
            settings.scale = Double(min(original, max(1, pixels))) / Double(max(1, original))
        }
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
            .navigationTitle("Export Image")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save…") { commitDimension(editingDimension); dismiss(); save() }
                }
            }
        }
        .onAppear { syncDimensions() }
        .onChange(of: settings.scale) { _, _ in syncDimensions() }
        .onChange(of: editingDimension) { previous, _ in commitDimension(previous) }
        .task {
            // One serial worker, rather than spawning another full encode for
            // each slider event. Its decoded source is released with the sheet.
            let worker = RAWDeveloper(colorSpace: colorSpace, rawSettings: rawSettings)
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
        .frame(width: 460, height: 460)
        #endif
    }

    private func options(for format: ExportFormat) -> some View {
        Form {
            LabeledContent("Linear size", value: settings.scale.formatted(.percent.precision(.fractionLength(0))))
            Slider(value: Binding(get: { min(1, max(0.25, (settings.scale * 20).rounded() / 20)) },
                                  set: { settings.scale = ($0 * 20).rounded() / 20 }),
                   in: 0.25...1, step: 0.05) { Text("Linear size") }
            HStack {
                TextField("Width", text: Binding(get: { widthText }, set: {
                    widthText = $0; updateDimension($0, dimension: .width)
                }))
                    .focused($editingDimension, equals: .width)
                    .onSubmit { commitDimension(.width) }
                    .accessibilityLabel("Export width in pixels")
                Text("×").foregroundStyle(.secondary)
                TextField("Height", text: Binding(get: { heightText }, set: {
                    heightText = $0; updateDimension($0, dimension: .height)
                }))
                    .focused($editingDimension, equals: .height)
                    .onSubmit { commitDimension(.height) }
                    .accessibilityLabel("Export height in pixels")
                Text("px").foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("\(Double(outputWidth) * Double(outputHeight) / 1_000_000, format: .number.precision(.fractionLength(2))) MP")
                    .foregroundStyle(.secondary).fixedSize()
            }
            .textFieldStyle(.roundedBorder)
            .monospacedDigit()
            if format != .tiff {
                LabeledContent("Quality", value: settings.quality.formatted(.percent.precision(.fractionLength(0))))
                Slider(value: $settings.quality, in: 0...1, step: 0.01) { Text("Quality") }
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
            if format == .tiff {
                Picker("Version", selection: $settings.tiffHDR) {
                    Text("SDR").tag(false)
                    Text("HDR").tag(true)
                }.pickerStyle(.segmented)
                Picker("Bit depth", selection: $settings.tiff16Bit) {
                    Text("8 bit").tag(false)
                    Text("16 bit").tag(true)
                }.pickerStyle(.segmented)
                Text("LZW compression. HDR preserves the full rendition by scaling it down by HDR Gain to fit a standard SDR file.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if format == .jpeg {
                Toggle("HDR gain map", isOn: $settings.jpegHDR)
                    .disabled(!hdrEnabled)
                    .help("Save an SDR JPEG with an ISO HDR gain map for compatible viewers.")
            }
            if format == .heif || (format == .jpeg && settings.jpegHDR) {
                Toggle("RGB gain map", isOn: $settings.rgbGainMap).disabled(!hdrEnabled)
                Text(settings.rgbGainMap ? "Color gain map" : "Monochrome gain map")
                    .foregroundStyle(.secondary)
                Toggle("Half-size gain map", isOn: $settings.halfSizeGainMap).disabled(!hdrEnabled)
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
