import SwiftUI

/// Draft text never reaches the renderer until the complete pair is valid.
struct DyeMatrixField: View {
    @Binding var mixers: DyeMixers
    @Binding var rgb: [Double]
    @State private var draft = ""
    @State private var invalid = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Cross Processing code", text: $draft)
                .font(.body.monospaced()).textFieldStyle(.roundedBorder)
                .focused($focused)
                .onAppear { refresh() }
                .onSubmit { if commit() { focused = false } }
                .onChange(of: focused) { _, active in if !active { _ = commit() } }
                .onChange(of: mixers) { _, _ in refresh() }
                .onChange(of: rgb) { _, _ in refresh() }
                .help("Base32 code containing the matrix seed, Brew strength, and RGB slider values. Paste a code and press Return to restore them together.")
            if invalid {
                Text("Invalid Cross Processing code. Settings are unchanged.")
                    .font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func refresh() {
        draft = CrossProcessingCode.encode(mixers: mixers, rgb: rgb)
        invalid = false
    }

    @discardableResult private func commit() -> Bool {
        if draft == CrossProcessingCode.encode(mixers: mixers, rgb: rgb) { return true }
        if let value = CrossProcessingCode.decode(draft) {
            invalid = false
            mixers = value.mixers
            rgb = value.rgb
            return true
        }
        guard let parsed = DyeMixers(text: draft) else { invalid = true; return false }
        invalid = false
        if parsed != mixers { mixers = parsed }
        return true
    }
}
