import SwiftUI

struct LibraryEntry: Identifiable, Codable {
    var id = UUID()
    var parent: UUID?
    var name: String
    var recipe: DevelopmentRecipe?
    var selection: SettingsPasteSelection?
    var isFolder: Bool { recipe == nil }
}

@MainActor @Observable final class EditLibrary {
    static let shared = EditLibrary()
    private(set) var entries: [LibraryEntry] = []
    var error: String?
    private let url: URL
    private var readable = true
    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dark Melon/EditLibrary.json")
        do {
            if FileManager.default.fileExists(atPath: self.url.path) {
                entries = try JSONDecoder().decode([LibraryEntry].self, from: Data(contentsOf: self.url))
                for i in entries.indices {
                    if var recipe = entries[i].recipe {
                        recipe.mapping.vertexWarp = OKLabVertexWarp.expanded(recipe.mapping.vertexWarp, space: recipe.colorSpace)
                        entries[i].recipe = recipe
                    }
                }
            }
        } catch { readable = false; self.error = error.localizedDescription }
    }
    private func save(_ updated: [LibraryEntry]) {
        guard readable else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(updated).write(to: url, options: .atomic)
            entries = updated
        } catch { self.error = error.localizedDescription }
    }
    func addFolder(_ name: String, parent: UUID?) {
        save(entries + [LibraryEntry(parent: parent, name: name)])
    }
    func addEdit(_ name: String, parent: UUID?, recipe: DevelopmentRecipe, selection: SettingsPasteSelection) {
        var mapping = selection.applying(recipe.mapping, to: ToneMapping())
        if selection.whiteBalance { mapping.rawWhiteBalance = recipe.mapping.rawWhiteBalance }
        let selected = DevelopmentRecipe(colorSpace: recipe.colorSpace, mapping: mapping,
            rawSettings: selection.raw ? recipe.rawSettings : nil)
        save(entries + [LibraryEntry(parent: parent, name: name, recipe: selected, selection: selection)])
    }
    func move(_ id: UUID, to parent: UUID?) {
        guard let index = entries.firstIndex(where: { $0.id == id }), !entries[index].isFolder else { return }
        var updated = entries; updated[index].parent = parent; save(updated)
    }
    func remove(_ id: UUID) {
        var removed: Set<UUID> = [id]
        var count = 0
        while removed.count != count {
            count = removed.count
            for entry in entries where entry.parent.map(removed.contains) == true { removed.insert(entry.id) }
        }
        save(entries.filter { !removed.contains($0.id) })
    }
}

struct EditLibraryView: View {
    @State private var library = EditLibrary.shared
    @State private var folder: UUID?
    @State private var snapshot: DevelopmentRecipe?
    @State private var selection: SettingsPasteSelection?
    @State private var choosingParts = false
    @State private var namingFolder = false
    @State private var namingEdit = false
    @State private var deleting: LibraryEntry?
    @State private var name = ""
    let current: DevelopmentRecipe?
    let filename: String
    let apply: (DevelopmentRecipe, SettingsPasteSelection) -> Void

    private var children: [LibraryEntry] {
        library.entries.filter { $0.parent == folder }.sorted {
            if $0.isFolder != $1.isFolder { return $0.isFolder }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if let folder {
                    Button("Back", systemImage: "chevron.left") {
                        self.folder = library.entries.first { $0.id == folder }?.parent
                    }.labelStyle(.iconOnly)
                }
                Text(library.entries.first { $0.id == folder }?.name ?? String(localized: "Library"))
                    .font(.headline).lineLimit(1)
                Spacer()
                Menu {
                    Button("Add Folder", systemImage: "folder.badge.plus") { name = ""; namingFolder = true }
                    Button("Add Edit", systemImage: "plus") {
                        snapshot = current; selection = nil; choosingParts = true
                    }.disabled(current == nil)
                } label: { Label("Add", systemImage: "plus") }
                .menuStyle(.borderlessButton).fixedSize()
            }.padding(12)
            List {
                ForEach(children) { entry in
                    Button {
                        if entry.isFolder { folder = entry.id }
                        else if let recipe = entry.recipe, let parts = entry.selection { apply(recipe, parts) }
                    } label: {
                        HStack {
                            Label(entry.name, systemImage: entry.isFolder ? "folder" : "slider.horizontal.3")
                            Spacer()
                            if entry.isFolder { Image(systemName: "chevron.right").foregroundStyle(.secondary) }
                        }.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!entry.isFolder && current == nil)
                    .contextMenu {
                        if !entry.isFolder {
                            Menu("Move to") {
                                Button("Library") { library.move(entry.id, to: nil) }
                                ForEach(library.entries.filter(\.isFolder)) { target in
                                    Button(target.name) { library.move(entry.id, to: target.id) }
                                }
                            }
                        }
                        Button("Delete", role: .destructive) { deleting = entry }
                    }
                }
            }.listStyle(.sidebar)
            if let error = library.error { Text(error).foregroundStyle(.red).font(.caption).padding() }
        }
        .sheet(isPresented: $choosingParts, onDismiss: {
            if selection != nil { namingEdit = true }
        }) {
            SettingsPasteOptions(apply: { parts in
                selection = parts
                name = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
            }, title: "Add Edit", actionTitle: "Next")
        }
        .alert("Add Folder", isPresented: $namingFolder) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Add") { library.addFolder(name.trimmingCharacters(in: .whitespacesAndNewlines), parent: folder) }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("Add Edit", isPresented: $namingEdit) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                if let snapshot, let selection {
                    library.addEdit(name.trimmingCharacters(in: .whitespacesAndNewlines), parent: folder, recipe: snapshot, selection: selection)
                }
            }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("Delete", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) { if let deleting { library.remove(deleting.id) }; deleting = nil }
        } message: { Text("Delete this library item and any edits inside it?") }
    }
}
