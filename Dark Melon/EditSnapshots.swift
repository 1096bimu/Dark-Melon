import SwiftUI

nonisolated struct SnapshotEdit: Codable, Equatable, Sendable {
    var colorSpace: ProcessingColorSpace
    var mapping: ToneMapping
    var rawSettings: RAWSettings?
    init(_ recipe: DevelopmentRecipe) {
        colorSpace = recipe.colorSpace; mapping = recipe.mapping; rawSettings = recipe.rawSettings
    }
    var recipe: DevelopmentRecipe {
        DevelopmentRecipe(colorSpace: colorSpace, mapping: mapping, rawSettings: rawSettings)
    }
}

nonisolated struct NamedSnapshot: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var edit: SnapshotEdit
    var createdAt: Date? = Date()
}

nonisolated struct DraftSnapshot: Codable, Equatable, Sendable {
    var edit: SnapshotEdit
    var modifiedAt: Date?
}

nonisolated struct SnapshotSession: Equatable {
    var selected = "saved"
    var draft: SnapshotEdit?
    var draftModifiedAt: Date?
    var persistedDraft: DraftSnapshot? {
        draft.map { DraftSnapshot(edit: $0, modifiedAt: draftModifiedAt) }
    }
    func recipeForSaving(_ current: DevelopmentRecipe) -> DevelopmentRecipe {
        var result = current
        result.draftSnapshot = draft == SnapshotEdit(current) ? nil : persistedDraft
        return result
    }
    mutating func didSave(_ recipe: DevelopmentRecipe) {
        if draft == SnapshotEdit(recipe) { draft = nil; draftModifiedAt = nil }
        if selected == "unsaved" { selected = "saved" }
    }
}

struct EditSnapshotsView: View {
    let saved: Bool
    let savedAt: Date?
    let draftAt: Date?
    let draft: Bool
    let snapshots: [NamedSnapshot]
    let selected: String
    let select: (String) -> Void
    let create: (String) -> Void
    let update: (String) -> Void
    let delete: (UUID) -> Void
    let discardDraft: () -> Void
    @State private var naming = false
    @State private var name = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Snapshots").font(.headline)
                Spacer()
                Button { name = ""; naming = true } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.borderless).fixedSize()
                .help("Create Snapshot")
            }.padding(12)
            List {
                if saved {
                    row("Saved Edit", key: "saved", date: savedAt)
                        .contextMenu { Button("Update with Current") { update("saved") } }
                }
                if draft {
                    row("Unsaved Edit", key: "unsaved", date: draftAt)
                        .contextMenu {
                            Button("Update with Current") { update("unsaved") }
                            Button("Discard Unsaved Edit", role: .destructive, action: discardDraft)
                        }
                }
                ForEach(snapshots) { snapshot in
                    Button { select(snapshot.id.uuidString) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(snapshot.name)
                                if let date = snapshot.createdAt { SnapshotTimestamp(date: date) }
                            }
                            Spacer()
                            if selected == snapshot.id.uuidString { Image(systemName: "checkmark") }
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .contextMenu {
                        Button("Update with Current") { update(snapshot.id.uuidString) }
                        Button("Delete Snapshot", role: .destructive) { delete(snapshot.id) }
                    }
                }
            }.listStyle(.plain)
        }
        .alert("Create Snapshot", isPresented: $naming) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Create") { create(name.trimmingCharacters(in: .whitespacesAndNewlines)) }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
    private func row(_ title: LocalizedStringKey, key: String, date: Date?) -> some View {
        Button { select(key) } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let date { SnapshotTimestamp(date: date) }
                }
                Spacer()
                if selected == key { Image(systemName: "checkmark") }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}


struct SnapshotTimestamp: View {
    let date: Date
    static func label(for date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            let elapsed = max(0, now.timeIntervalSince(date))
            if elapsed < 60 { return String(localized: "Just now") }
            let formatter = RelativeDateTimeFormatter()
            let count = elapsed < 3600 ? Int(elapsed / 60) : Int(elapsed / 3600)
            return formatter.localizedString(from: elapsed < 3600
                ? DateComponents(minute: -count) : DateComponents(hour: -count))
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Text(Self.label(for: date, now: context.date))
                .font(.caption).foregroundStyle(.secondary)
                .help(date.formatted(date: .complete, time: .standard))
        }
    }
}
