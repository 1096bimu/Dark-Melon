import SwiftUI

nonisolated enum InfoPillField: Int, CaseIterable, Identifiable {
    case name = 1, position = 2, fileSize = 4, dimensions = 8, megapixels = 16
    case format = 32, exposure = 64, camera = 128, captured = 256

    static let preferenceKey = "preview.infoPillFields"
    static let standard = allCases.filter { $0 != .position }.reduce(0) { $0 | $1.rawValue }
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .name: String(localized: "File name")
        case .position: String(localized: "Position in folder")
        case .fileSize: String(localized: "File size")
        case .dimensions: String(localized: "Dimensions")
        case .megapixels: String(localized: "Megapixels")
        case .format: String(localized: "Format")
        case .exposure: String(localized: "Exposure")
        case .camera: String(localized: "Camera")
        case .captured: String(localized: "Date captured")
        }
    }
    func isVisible(in fields: Int) -> Bool { fields & rawValue != 0 }
    func settingVisible(_ visible: Bool, in fields: Int) -> Int {
        visible ? fields | rawValue : fields & ~rawValue
    }
}

nonisolated struct PreviewInfoContent: Equatable {
    struct Fact: Equatable, Identifiable {
        let field: InfoPillField
        let text: String
        var id: InfoPillField { field }
    }
    let name: String?
    let facts: [Fact]
    let details: String?
    var isEmpty: Bool { name == nil && facts.isEmpty && details == nil }

    init(current: URL?, resolution: CGSize, fileSize: Int64?, metadata: CameraMetadata?, position: String?, fields: Int) {
        name = InfoPillField.name.isVisible(in: fields)
            ? current?.deletingPathExtension().lastPathComponent ?? "Dark Melon" : nil
        var facts: [Fact] = []
        if InfoPillField.position.isVisible(in: fields), let position {
            facts.append(Fact(field: .position, text: position))
        }
        if InfoPillField.fileSize.isVisible(in: fields), let size = fileSize ?? metadata?.fileSize {
            facts.append(Fact(field: .fileSize, text: ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))
        }
        if resolution.width > 0, resolution.height > 0, resolution.width.isFinite, resolution.height.isFinite {
            let megapixels = (Double(resolution.width * resolution.height) / 1_000_000)
                .formatted(.number.precision(.fractionLength(1))) + " MP"
            if InfoPillField.dimensions.isVisible(in: fields) {
                let dimensions = "\(Int(resolution.width)) × \(Int(resolution.height))"
                facts.append(Fact(field: .dimensions, text: dimensions + (InfoPillField.megapixels.isVisible(in: fields) ? "  " + megapixels : "")))
            } else if InfoPillField.megapixels.isVisible(in: fields) {
                facts.append(Fact(field: .megapixels, text: megapixels))
            }
        }
        if InfoPillField.format.isVisible(in: fields), let current, !current.pathExtension.isEmpty {
            facts.append(Fact(field: .format, text: current.pathExtension.uppercased()))
        }
        self.facts = facts

        var details: [String] = []
        if let metadata {
            if InfoPillField.camera.isVisible(in: fields), let camera = metadata.camera, !camera.isEmpty {
                details.append(camera)
            }
            if InfoPillField.exposure.isVisible(in: fields) {
                if let aperture = metadata.aperture { details.append("f/" + aperture.formatted(.number.precision(.fractionLength(1)))) }
                if let exposure = metadata.exposure {
                    details.append(exposure < 1
                        ? "1/\((1 / exposure).formatted(.number.precision(.fractionLength(0))))s"
                        : exposure.formatted(.number.precision(.fractionLength(1))) + "s")
                }
                if let iso = metadata.iso { details.append("ISO " + iso.formatted(.number.precision(.fractionLength(0)))) }
                if let focalLength = metadata.focalLength { details.append(focalLength.formatted(.number.precision(.fractionLength(0))) + "mm") }
            }
            if InfoPillField.captured.isVisible(in: fields), let date = metadata.captureDate {
                var format = Date.FormatStyle(date: .abbreviated, time: .shortened)
                format.timeZone = metadata.captureTimeZone
                details.append(date.formatted(format))
            }
        }
        self.details = details.isEmpty ? nil : details.joined(separator: "  ·  ")
    }
}

/// Three levels of metadata, following Pictty's HUDOverlay presentation.
struct PreviewInfoPill: View {
    let current: URL?
    let resolution: CGSize
    let fileSize: Int64?
    let metadata: CameraMetadata?
    let position: String?
    @AppStorage(InfoPillField.preferenceKey) private var fields = InfoPillField.standard

    var body: some View {
        let info = PreviewInfoContent(current: current, resolution: resolution, fileSize: fileSize,
            metadata: metadata, position: position, fields: fields)
        if !info.isEmpty {
            VStack(spacing: 3) {
                if let name = info.name {
                    Text(name)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if !info.facts.isEmpty {
                    HStack(spacing: 9) {
                        ForEach(Array(info.facts.enumerated()), id: \.element.id) { index, fact in
                            if index > 0 { Circle().fill(.white.opacity(0.22)).frame(width: 2.5, height: 2.5) }
                            if fact.field == .position {
                                Label(fact.text, systemImage: "photo.stack")
                            } else {
                                Text(fact.text)
                            }
                        }
                    }
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                }
                if let details = info.details {
                    Text(details)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.42))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.top, 1)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .modifier(ShellPill(height: nil, tint: 0.22))
        }
    }
}
