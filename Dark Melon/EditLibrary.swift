import SwiftUI
import UniformTypeIdentifiers

struct LibraryEntry: Identifiable, Codable {
    var id = UUID()
    var parent: UUID?
    var name: String
    var recipe: DevelopmentRecipe?
    var selection: SettingsPasteSelection?
    var lutID: UUID? = nil
    var isFolder: Bool { recipe == nil && lutID == nil }
}

@MainActor @Observable final class EditLibrary {
    static let shared = EditLibrary()
    private(set) var entries: [LibraryEntry] = []
    var error: String?
    var importingLUT = false
    private let url: URL
    private let lutStore: LUTStore
    private let preferences: UserDefaults
    private let defaultKey: String
    private(set) var rawDefaultID: UUID?
    var rawDefaultPreset: RAWDefaultPreset? {
        guard let entry = entries.first(where: { $0.id == rawDefaultID }),
              let recipe = entry.recipe, let selection = entry.selection else { return nil }
        return RAWDefaultPreset(recipe: recipe, selection: selection)
    }
    func useAsRAWDefault(_ id: UUID?) {
        guard id == nil || entries.contains(where: { $0.id == id && $0.recipe != nil }) else { return }
        rawDefaultID = id
        preferences.set(id?.uuidString, forKey: defaultKey)
    }
    private var readable = true
    init(url: URL? = nil, lutStore: LUTStore = .shared, preferences: UserDefaults = .standard) {
        self.preferences = preferences
        defaultKey = url.map { "rawDefaultPreset:" + $0.path } ?? "rawDefaultPreset"
        rawDefaultID = preferences.string(forKey: defaultKey).flatMap(UUID.init(uuidString:))
        self.lutStore = lutStore
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dark Melon/EditLibrary.json")
        do {
            if FileManager.default.fileExists(atPath: self.url.path) {
                entries = try Self.decode(Data(contentsOf: self.url))
            } else if url == nil, let bundled = Bundle.main.url(forResource: "BundledLUTLibrary", withExtension: "json", subdirectory: "BundledLUTs")
                ?? Bundle.main.url(forResource: "BundledLUTLibrary", withExtension: "json") {
                entries = try Self.decode(Data(contentsOf: bundled))
                save(entries)
            }
            if let rawDefaultID, !entries.contains(where: { $0.id == rawDefaultID && $0.recipe != nil }) {
                useAsRAWDefault(nil)
            }
        } catch { readable = false; self.error = error.localizedDescription }
    }
    /// Library recipes use the same additive-field migrations as image sidecars.
    private static func decode(_ data: Data) throws -> [LibraryEntry] {
        guard var items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SettingsPasteSelection())) as! [String: Any]
        for i in items.indices {
            if let document = items[i]["recipe"] as? [String: Any] {
                let recipe = try DevelopmentRecipe.decode(JSONSerialization.data(withJSONObject: document))
                items[i]["recipe"] = try JSONSerialization.jsonObject(with: recipe.encoded())
            }
            if let selection = items[i]["selection"] as? [String: Any] {
                items[i]["selection"] = defaults.merging(selection) { _, saved in saved }
            }
        }
        return try JSONDecoder().decode([LibraryEntry].self, from: JSONSerialization.data(withJSONObject: items))
    }

    private func save(_ updated: [LibraryEntry]) {
        do {
            if !readable {
                // Never replace an unreadable library until its original bytes are safe.
                let backup = url.deletingPathExtension().appendingPathExtension("backup-\(UUID().uuidString).json")
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.copyItem(at: url, to: backup)
                }
                readable = true
                error = String(localized: "The unreadable library was backed up. A new library has been created.")
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(updated).write(to: url, options: .atomic)
            entries = updated
            if let rawDefaultID, !entries.contains(where: { $0.id == rawDefaultID && $0.recipe != nil }) {
                useAsRAWDefault(nil)
            }
        } catch { self.error = error.localizedDescription }
    }
    func addFolder(_ name: String, parent: UUID?) {
        save(entries + [LibraryEntry(parent: parent, name: name)])
    }
    func addEdit(_ name: String, parent: UUID?, recipe: DevelopmentRecipe, selection: SettingsPasteSelection) {
        var mapping = selection.applying(recipe.mapping, to: ToneMapping())
        if selection.contains(.rawWhiteBalance) { mapping.rawWhiteBalance = recipe.mapping.rawWhiteBalance }
        let selected = DevelopmentRecipe(colorSpace: recipe.colorSpace, mapping: mapping,
            rawSettings: PasteItem.rawItems.contains(where: selection.contains) ? recipe.rawSettings : nil)
        save(entries + [LibraryEntry(parent: parent, name: name, recipe: selected, selection: selection)])
    }
    func addLUTs(_ sources: [URL], parent: UUID?) async {
        guard !importingLUT, !sources.isEmpty else { return }
        importingLUT = true
        error = nil
        defer { importingLUT = false }
        var imported: [LibraryEntry] = []
        var failures: [String] = []
        let store = lutStore
        // Parse one cube at a time so a large selection doesn't multiply memory use.
        for source in sources {
            do {
                let id = try await Task.detached(priority: .userInitiated) {
                    try store.importFile(source)
                }.value
                imported.append(LibraryEntry(name: source.deletingPathExtension().lastPathComponent, lutID: id))
            } catch { failures.append("\(source.lastPathComponent): \(error.localizedDescription)") }
        }
        let destination = parent.flatMap { id in entries.contains(where: { $0.id == id && $0.isFolder }) ? id : nil }
        for index in imported.indices { imported[index].parent = destination }
        if !imported.isEmpty {
            save(entries + imported)
            for item in imported where !entries.contains(where: { $0.id == item.id }) {
                if let id = item.lutID { store.remove(id) }
            }
        }
        if !failures.isEmpty { error = ([error].compactMap { $0 } + failures).joined(separator: "\n") }
    }

    func rename(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = entries.firstIndex(where: { $0.id == id }),
              entries[index].name != name else { return }
        var updated = entries
        updated[index].name = name
        save(updated)
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
        let luts = entries.filter { removed.contains($0.id) }.compactMap(\.lutID)
        save(entries.filter { !removed.contains($0.id) })
        for id in luts where !entries.contains(where: { $0.lutID == id }) { lutStore.remove(id) }
    }
}

struct EditLibraryView: View {
    @Environment(\.lockedFilmItems) private var lockedItems
    @State private var library = EditLibrary.shared
    @State private var folder: UUID?
    @State private var snapshot: DevelopmentRecipe?
    @State private var selection: SettingsPasteSelection?
    @State private var choosingParts = false
    @State private var choosingLUT = false
    @State private var configuringLUT: LibraryEntry?
    @State private var namingFolder = false
    @State private var namingEdit = false
    @State private var deleting: LibraryEntry?
    @State private var renaming: LibraryEntry?
    @State private var name = ""
    let current: DevelopmentRecipe?
    @Binding var selectedLUT: UUID?
    let filename: String
    let apply: (String, DevelopmentRecipe, SettingsPasteSelection) -> Void

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
                    Button("Add Current Edit", systemImage: "slider.horizontal.3") {
                        snapshot = current; selection = nil; choosingParts = true
                    }.disabled(current == nil)
                    Button("Add LUT…", systemImage: "cube") { choosingLUT = true }
                } label: { Label("Add", systemImage: "plus") }
                .disabled(library.importingLUT)
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }.padding(12)
            List {
                ForEach(children) { entry in
                    Button {
                        if entry.isFolder { folder = entry.id }
                        else if let id = entry.lutID { selectedLUT = selectedLUT == id ? nil : id }
                        else if let recipe = entry.recipe, let parts = entry.selection { apply(entry.name, recipe, parts) }
                    } label: {
                        HStack {
                            Label(entry.name, systemImage: entry.isFolder ? "folder" : entry.lutID != nil ? "cube" : "slider.horizontal.3")
                            Spacer()
                            if entry.isFolder { Image(systemName: "chevron.right").foregroundStyle(.secondary) }
                            else if let id = entry.lutID, id == selectedLUT { Image(systemName: "checkmark") }
                            else if entry.id == library.rawDefaultID {
                                Image(systemName: "camera.aperture").foregroundStyle(.secondary)
                                    .help("RAW Default")
                            }
                        }.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(entry.lutID != nil && entry.lutID == selectedLUT ? Color.accentColor.opacity(0.2) : Color.clear)
                    .disabled((entry.recipe != nil && current == nil) || (entry.lutID != nil && lockedItems.contains(.lut)))
                    .contextMenu {
                        Button("Rename…", systemImage: "pencil") { name = entry.name; renaming = entry }
                        if entry.recipe != nil {
                            Button(LocalizedStringKey(library.rawDefaultID == entry.id ? "Clear RAW Default" : "Use as RAW Default"),
                                   systemImage: "camera.aperture") {
                                library.useAsRAWDefault(library.rawDefaultID == entry.id ? nil : entry.id)
                            }
                        }
                        if entry.lutID != nil {
                            Button("Configure LUT…", systemImage: "slider.horizontal.3") { configuringLUT = entry }
                                .disabled(lockedItems.contains(.lut))
                            Divider()
                        }
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
        .sheet(item: $configuringLUT) { entry in
            if let id = entry.lutID { LUTConfigurationView(id: id, name: entry.name, hdrEnabled: current?.mapping.hdrEnabled) }
        }
        .fileImporter(isPresented: $choosingLUT, allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data], allowsMultipleSelection: true) { (result: Result<[URL], Error>) in
            switch result {
            case .success(let urls): Task { await library.addLUTs(urls, parent: folder) }
            case .failure(let error): library.error = error.localizedDescription
            }
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
        .alert("Rename", isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } }
        ), presenting: renaming) { entry in
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") { library.rename(entry.id, to: name); renaming = nil }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("Delete", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) { if let deleting {
                library.remove(deleting.id)
                if let selectedLUT, !library.entries.contains(where: { $0.lutID == selectedLUT }) { self.selectedLUT = nil }
            }; deleting = nil }
        } message: { Text("Delete this library item and any edits inside it?") }
    }
}
