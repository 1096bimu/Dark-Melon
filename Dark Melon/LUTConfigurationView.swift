import SwiftUI

struct LUTConfigurationView: View {
    let id: UUID
    let name: String
    var hdrEnabled: Bool? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var configuration = LUTConfiguration()
    @State private var dimension: Int?
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(name).font(.headline).lineLimit(2)
            Form {
                Picker("Intended input gamma/gamut", selection: $configuration.input) {
                    ForEach(LUTProfile.allCases) { Text($0.name).tag($0) }
                }
                LabeledContent("LUT transform grid size") {
                    if let dimension { Text("\(dimension) × \(dimension) × \(dimension)").monospacedDigit() }
                    else { ProgressView().controlSize(.small) }
                }
                Picker("Intended output gamma/gamut", selection: $configuration.output) {
                    ForEach(LUTProfile.allCases) { Text($0.name).tag($0) }
                }
            }.formStyle(.grouped)
            if configuration.input.isLog {
                Text("Log-input LUTs require HDR Gain to be enabled. The fully processed HDR image is used as input, and the LUT produces SDR output. With HDR Gain off, the LUT is bypassed.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if hdrEnabled == false {
                    Label("HDR Gain is off. This LUT is currently bypassed.", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                }
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    let value = configuration
                    saving = true
                    Task {
                        do {
                            try await Task.detached { try LUTStore.shared.configure(id, as: value) }.value
                            dismiss()
                        } catch { self.error = error.localizedDescription; saving = false }
                    }
                }.keyboardShortcut(.defaultAction).disabled(dimension == nil || saving)
            }
        }
        .padding()
        .frame(minWidth: 450, minHeight: 280)
        .task {
            let result = await Task.detached { (LUTStore.shared.cube(for: id)?.dimension, LUTStore.shared.configuration(for: id)) }.value
            dimension = result.0; configuration = result.1
            if dimension == nil { error = String(localized: "Invalid or unsupported .cube LUT.") }
        }
    }
}
