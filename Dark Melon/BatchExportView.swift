#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

struct BatchExportView: View {
    let directory: URL
    @Environment(\.dismiss) private var dismiss
    @State private var browser = ImageBrowserModel()
    @State private var selection: Set<URL> = []
    @State private var settings = HEIFSettings.restored()
    @State private var sample: RAWDevelopment?
    @State private var sampleRecipe: DevelopmentRecipe?
    @State private var sources: [URL] = []
    @State private var showingOptions = false
    @State private var choosingDestination = false
    @State private var destinationAfterOptions = false
    @State private var busy = false
    @State private var completed = 0
    @State private var status = ""
    @State private var failures: [String] = []
    @State private var job: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                ImageFileBrowser(selectedURL: nil, open: { _ in }, model: browser, selection: $selection)
                    .disabled(busy)
                HStack {
                    Button("Select All") { selection = Set(browser.batchFiles.map(\.url)) }
                    Button("Deselect All") { selection.removeAll() }
                    Spacer()
                    Text("\(selection.count) selected").foregroundStyle(.secondary)
                }.disabled(busy)
                if busy { ProgressView(value: Double(completed), total: Double(max(1, sources.count))) }
                if !status.isEmpty { Text(status).font(.callout) }
                if !failures.isEmpty {
                    ScrollView { Text(failures.joined(separator: "\n")).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 100)
                }
            }
            .padding()
            .navigationTitle("Batch Export")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(busy ? "Cancel Export" : "Close") {
                        if busy { job?.cancel() } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Export Selected…", action: prepareOptions)
                        .disabled(busy || selection.isEmpty || browser.loading)
                }
            }
        }
        .frame(minWidth: 600, minHeight: 500)
        .interactiveDismissDisabled(busy)
        .task { browser.choose(directory) }
        .onDisappear { job?.cancel() }
        .onChange(of: settings) { _, value in value.remember() }
        .sheet(isPresented: $showingOptions, onDismiss: {
            if destinationAfterOptions { destinationAfterOptions = false; choosingDestination = true }
        }) {
            if let sample, let sampleRecipe {
                HEIFExportOptions(settings: $settings, width: sample.width, height: sample.height,
                                  hdrEnabled: true, sourceURL: sample.url, mapping: sampleRecipe.mapping,
                                  colorSpace: sampleRecipe.colorSpace, rawSettings: sampleRecipe.rawSettings ?? sample.rawDefaults ?? RAWSettings(),
                                  save: { destinationAfterOptions = true })
                    .safeAreaInset(edge: .bottom) {
                        Text("Size and estimate use the first selected image. The same size percentage applies to each image. Images use saved settings when available, otherwise automatic adjustments.")
                            .font(.caption).foregroundStyle(.secondary).padding()
                    }
            }
        }
        .fileImporter(isPresented: $choosingDestination, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let destination): export(to: destination)
            case .failure(let error): status = error.localizedDescription
            }
        }
    }

    private func prepareOptions() {
        sources = browser.batchFiles.filter { selection.contains($0.url) }.map(\.url)
        guard let first = sources.first else { return }
        busy = true; completed = 0; failures = []; status = "Preparing export settings…"
        job = Task {
            defer { busy = false }
            do {
                let prepared = try await BrowserFileDevelopment.load(first, bins: 512)
                try Task.checkCancellation()
                sampleRecipe = prepared.recipe; sample = prepared.development
                status = ""; showingOptions = true
            } catch is CancellationError { status = "Cancelled." }
            catch { status = error.localizedDescription }
        }
    }

    private func export(to destination: URL) {
        let snapshot = settings
        let files = sources
        busy = true; completed = 0; failures = []; status = "Preparing concurrent exports…"
        sample = nil; sampleRecipe = nil
        job = Task {
            let access = destination.startAccessingSecurityScopedResource()
            defer { if access { destination.stopAccessingSecurityScopedResource() }; busy = false }
            await BatchExportRunner.run(files: files, destination: destination, settings: snapshot) { result, active in
                if !result.cancelled {
                    completed += 1
                    if let error = result.error { failures.append("\(result.source.lastPathComponent): \(error)") }
                }
                status = "Completed \(completed) of \(files.count) · \(active) running"
            }
            status = "\(Task.isCancelled ? "Cancelled. " : "")Exported \(completed - failures.count) of \(files.count) images.\(failures.isEmpty ? "" : " \(failures.count) failed.")"
        }
    }
}

#endif
