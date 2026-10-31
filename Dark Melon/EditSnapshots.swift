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
    var comparisonSelection: (([String]) -> Void)? = nil
    var comparisonKeys: [String] = []
    var openReference: ((String) -> Void)? = nil
    var mutationsDisabled = false
    @State private var selectedRows: Set<String> = []
    @State private var anchor: String?
    private var orderedKeys: [String] {
        (saved ? ["saved"] : []) + (draft ? ["unsaved"] : []) + snapshots.map { $0.id.uuidString }
    }
    private func choose(_ key: String) {
        #if os(macOS)
        let flags = NSEvent.modifierFlags
        var next = selectedRows.isEmpty ? Set([selected]) : selectedRows
        if flags.contains(.shift), let a = orderedKeys.firstIndex(of: anchor ?? selected), let b = orderedKeys.firstIndex(of: key) {
            let range = Set(orderedKeys[min(a,b)...max(a,b)])
            next = flags.contains(.command) ? next.union(range) : range
        } else if flags.contains(.command) {
            if !next.insert(key).inserted { next.remove(key) }
            anchor = key
        } else {
            next = [key]; anchor = key
        }
        selectedRows = next
        comparisonSelection?(orderedKeys.filter(next.contains))
        if !flags.contains(.command) && !flags.contains(.shift) { select(key) }
        #else
        select(key)
        #endif
    }
    private var comparisonSet: Set<String> { selectedRows.isEmpty ? [selected] : selectedRows }
    private func toggleComparison(_ key: String) {
        var next = comparisonSet
        if next.contains(key) { next.remove(key) }
        else {
            guard next.count < 4 else { return }
            next.insert(key)
        }
        selectedRows = next
        anchor = key
        comparisonSelection?(orderedKeys.filter(next.contains))
    }
    @ViewBuilder private func compareButton(_ key: String) -> some View {
        #if os(macOS)
        if let openReference { Button("Open as Reference") { openReference(key) } }
        #endif
        if comparisonSelection != nil {
            Button("Compare") { toggleComparison(key) }
                .disabled(!comparisonSet.contains(key) && comparisonSet.count >= 4)
        }
    }
    @State private var naming = false
    @State private var name = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Snapshots").font(.headline)
                Spacer()
                Button { guard !mutationsDisabled else { return }; name = ""; naming = true } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.borderless).fixedSize()
                .help("Create Snapshot")
                .disabled(mutationsDisabled)
            }.padding(12)
            List {
                if saved {
                    row("Saved Edit", key: "saved", date: savedAt)
                        .contextMenu {
                            compareButton("saved")
                            Button("Update with Current") { update("saved") }.disabled(mutationsDisabled)
                        }
                }
                if draft {
                    row("Unsaved Edit", key: "unsaved", date: draftAt)
                        .contextMenu {
                            compareButton("unsaved")
                            Button("Update with Current") { update("unsaved") }.disabled(mutationsDisabled)
                            Button("Discard Unsaved Edit", role: .destructive, action: discardDraft).disabled(mutationsDisabled)
                        }
                }
                ForEach(snapshots) { snapshot in
                    Button { choose(snapshot.id.uuidString) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(snapshot.name)
                                if let date = snapshot.createdAt { SnapshotTimestamp(date: date) }
                            }
                            Spacer()
                            if selectedRows.contains(snapshot.id.uuidString) || (selectedRows.isEmpty && selected == snapshot.id.uuidString) { Image(systemName: "checkmark") }
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .contextMenu {
                        compareButton(snapshot.id.uuidString)
                        Button("Update with Current") { update(snapshot.id.uuidString) }.disabled(mutationsDisabled)
                        Button("Delete Snapshot", role: .destructive) { delete(snapshot.id) }.disabled(mutationsDisabled)
                    }
                }
            }.listStyle(.plain)
        }
        .onAppear { selectedRows = Set(comparisonKeys) }
        .onChange(of: comparisonKeys) { _, keys in selectedRows = Set(keys) }
        .onChange(of: selected) { _, key in if selectedRows.count <= 1 { selectedRows = [key]; anchor = key } }
        .onChange(of: mutationsDisabled) { _, disabled in if disabled { naming = false } }
        .alert("Create Snapshot", isPresented: $naming) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Create") { if !mutationsDisabled { create(name.trimmingCharacters(in: .whitespacesAndNewlines)) } }
                .disabled(mutationsDisabled || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
    private func row(_ title: LocalizedStringKey, key: String, date: Date?) -> some View {
        Button { choose(key) } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let date { SnapshotTimestamp(date: date) }
                }
                Spacer()
                if selectedRows.contains(key) || (selectedRows.isEmpty && selected == key) { Image(systemName: "checkmark") }
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
