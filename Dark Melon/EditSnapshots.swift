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
}

nonisolated struct SnapshotSession: Equatable {
    var selected = "saved"
    var draft: SnapshotEdit?
}

struct EditSnapshotsView: View {
    let saved: Bool
    let draft: Bool
    let snapshots: [NamedSnapshot]
    let selected: String
    let select: (String) -> Void
    let create: (String) -> Void
    let delete: (UUID) -> Void
    @State private var naming = false
    @State private var name = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Snapshots").font(.headline)
                Spacer()
                Button { name = ""; naming = true } label: {
                    Image(systemName: "plus")
                }.help("Create Snapshot")
            }.padding(12)
            List {
                if saved { row("Saved Edit", key: "saved") }
                if draft { row("Unsaved Edit", key: "unsaved") }
                ForEach(snapshots) { snapshot in
                    Button { select(snapshot.id.uuidString) } label: {
                        HStack {
                            Text(snapshot.name)
                            Spacer()
                            if selected == snapshot.id.uuidString { Image(systemName: "checkmark") }
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .contextMenu { Button("Delete Snapshot", role: .destructive) { delete(snapshot.id) } }
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
    private func row(_ title: LocalizedStringKey, key: String) -> some View {
        Button { select(key) } label: {
            HStack {
                Text(title)
                Spacer()
                if selected == key { Image(systemName: "checkmark") }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
