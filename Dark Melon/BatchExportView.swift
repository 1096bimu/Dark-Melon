#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

struct BatchExportView: View {
    let directory: URL
    var film: FilmSettings? = nil
    let queue: ExportQueue
    @Environment(\.dismiss) private var dismiss
    @State private var browser = ImageBrowserModel()
    @State private var selection: Set<URL> = []
    @State private var settings = HEIFSettings.restored()
    @State private var sample: RAWDevelopment?
    @State private var sampleRecipe: DevelopmentRecipe?
    @State private var sources: [URL] = []
    @State private var preparedItems: [PreparedExportItem] = []
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
                                  percentageOnly: true, save: { _ in destinationAfterOptions = true })
                    .safeAreaInset(edge: .bottom) {
                        Text("Size and estimate use the first prepared image. The same size percentage applies to every image. Settings are captured during preparation; later edits and Film Lock changes do not affect this export.")
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
        settings.scale = min(1, max(0.25, (settings.scale * 20).rounded() / 20))
        sources = browser.batchFiles.filter { selection.contains($0.url) }.map(\.url)
        guard !sources.isEmpty else { return }
        busy = true; completed = 0; failures = []; status = String(localized: "Preparing export settings…")
        let capturedFilm = film
        let maximizeRange = UserDefaults.standard.bool(forKey: RAWSettings.maximizeRangePreferenceKey)
        let files = sources
        job = Task {
            defer { busy = false }
            do {
                let prepared = try await ExportPlan.prepare(files: files, film: capturedFilm, maximizeRAWRange: maximizeRange) { done, total in
                    completed = done
                    status = String(localized: "Preparing settings: \(done) of \(total)")
                }
                preparedItems = prepared.items; failures = prepared.failures
                guard let first = preparedItems.first else { status = String(localized: "No files could be prepared."); return }
                let recipe = first.recipe
                let worker = RAWDeveloper(colorSpace: recipe.colorSpace, rawSettings: recipe.rawSettings, rawWhiteBalance: recipe.mapping.rawWhiteBalance)
                let loaded = try await worker.develop(first.source)
                try Task.checkCancellation()
                sampleRecipe = recipe; sample = loaded
                status = ""; showingOptions = true
            } catch is CancellationError { status = String(localized: "Cancelled.") }
            catch { status = error.localizedDescription }
        }
    }

    private func export(to destination: URL) {
        let plan = ExportPlan(items: preparedItems, settings: settings, failures: failures)
        sample = nil; sampleRecipe = nil; job = nil
        queue.enqueue(plan, destination: .folder(destination))
        dismiss()
    }
}

#endif
