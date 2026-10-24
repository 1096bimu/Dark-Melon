#if os(macOS)
import SwiftUI

@MainActor @Observable final class ExportJob: Identifiable {
    enum Phase { case queued, running, finished, cancelled }
    let id = UUID()
    let title: String
    let total: Int
    var completed: Int
    var active = 0
    var phase = Phase.queued
    var failures: [String]

    init(_ plan: ExportPlan) {
        title = plan.items.count == 1 ? plan.items[0].source.lastPathComponent : String(localized: "Batch Export")
        total = plan.items.count + plan.failures.count
        completed = plan.failures.count
        failures = plan.failures
    }
}

@MainActor @Observable final class ExportQueue {
    static let shared = ExportQueue()
    enum Destination { case file(URL), folder(URL)
        var url: URL { switch self { case .file(let url), .folder(let url): url } }
    }
    private struct Request {
        let job: ExportJob
        let plan: ExportPlan
        let destination: Destination
        let cachedWorker: RAWDeveloper?
        let onSuccess: (() -> Void)?
    }
    private(set) var jobs: [ExportJob] = []
    private var pending: [Request] = []
    private var task: Task<Void, Never>?
    private var activeID: UUID?
    var running: Bool { task != nil }
    var symbol: String {
        if running { return "arrow.up.document" }
        if jobs.contains(where: { !$0.failures.isEmpty }) { return "exclamationmark.triangle" }
        return jobs.last?.phase == .cancelled ? "xmark.circle" : "checkmark.circle"
    }

    func enqueue(_ plan: ExportPlan, destination: Destination, cachedWorker: RAWDeveloper? = nil,
                 onSuccess: (() -> Void)? = nil) {
        let job = ExportJob(plan)
        jobs.removeAll { $0.phase == .finished || $0.phase == .cancelled }
        jobs.append(job)
        // Waiting jobs retain recipes, not full-resolution render caches.
        // Reuse the options cache only when execution can start immediately.
        pending.append(Request(job: job, plan: plan, destination: destination,
            cachedWorker: task == nil ? cachedWorker : nil, onSuccess: onSuccess))
        runNext()
    }

    func cancel(_ job: ExportJob) {
        if job.id == activeID { task?.cancel() }
        else { pending.removeAll { $0.job.id == job.id }; job.phase = .cancelled }
    }

    private func runNext() {
        guard task == nil, !pending.isEmpty else { return }
        let request = pending.removeFirst()
        let job = request.job
        activeID = job.id
        job.phase = .running
        task = Task {
            let destination = request.destination.url
            let destinationAccess = destination.startAccessingSecurityScopedResource()
            let sourceAccess = request.plan.items.map(\.source).filter { $0.startAccessingSecurityScopedResource() }
            defer {
                if destinationAccess { destination.stopAccessingSecurityScopedResource() }
                sourceAccess.forEach { $0.stopAccessingSecurityScopedResource() }
                task = nil; activeID = nil
                runNext()
            }
            switch request.destination {
            case .folder:
                await BatchExportRunner.run(plan: request.plan, destination: destination) { result, active in
                    if !result.cancelled {
                        job.completed += 1
                        if let error = result.error { job.failures.append("\(result.source.lastPathComponent): \(error)") }
                    }
                    job.active = active
                }
            case .file:
                do {
                    try Task.checkCancellation()
                    guard let item = request.plan.items.first else { throw CocoaError(.fileReadUnknown) }
                    let recipe = item.recipe
                    let worker = request.cachedWorker ?? RAWDeveloper(colorSpace: recipe.colorSpace,
                        rawSettings: recipe.rawSettings, rawWhiteBalance: recipe.mapping.rawWhiteBalance, lutConfiguration: item.lutConfiguration)
                    await worker.useLUTConfiguration(item.lutConfiguration)
                    job.active = 1
                    let bytes = try await worker.cachedExport(item.source, mapping: recipe.mapping, settings: request.plan.settings)
                    try Task.checkCancellation()
                    try await Self.write(bytes, to: destination)
                    job.completed += 1
                } catch is CancellationError { }
                catch { job.completed += 1; job.failures.append(error.localizedDescription) }
            }
            job.active = 0
            job.phase = Task.isCancelled ? .cancelled : .finished
            if !Task.isCancelled, job.failures.isEmpty { request.onSuccess?() }
        }
    }

    @concurrent private static func write(_ data: Data, to url: URL) async throws {
        try Task.checkCancellation()
        try data.write(to: url, options: .atomic)
    }
}

struct ExportQueueView: View {
    let queue: ExportQueue
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Exports").font(.headline)
                ForEach(queue.jobs) { job in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(job.title).lineLimit(1)
                            Spacer()
                            if job.phase == .queued || job.phase == .running {
                                Button("Cancel") { queue.cancel(job) }
                            }
                        }
                        switch job.phase {
                        case .queued: Text("Queued").foregroundStyle(.secondary)
                        case .running:
                            ProgressView(value: Double(job.completed), total: Double(max(1, job.total)))
                            Text("Completed \(job.completed) of \(job.total) · \(job.active) running").font(.caption)
                        case .finished: Text("Exported \(job.completed - job.failures.count) of \(job.total) images.").font(.caption)
                        case .cancelled: Text("Cancelled.").foregroundStyle(.secondary)
                        }
                        if !job.failures.isEmpty {
                            ScrollView { Text(job.failures.joined(separator: "\n")).font(.caption).textSelection(.enabled) }
                                .frame(maxHeight: 120)
                        }
                    }
                }
            }.padding()
        }.frame(width: 340, height: min(480, 60 + CGFloat(queue.jobs.count) * 160))
    }
}
#endif
