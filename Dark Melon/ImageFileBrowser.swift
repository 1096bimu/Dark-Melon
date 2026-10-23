import SwiftUI
import Combine
import UniformTypeIdentifiers
import Observation
import ImageIO
#if os(macOS)
import AppKit
#endif

enum BrowserGridLayout {
    static let thumbnailMinimum: CGFloat = 80
    static let spacing: CGFloat = 8
    static let padding: CGFloat = 8
    // Stay one point below the width at which a third thumbnail fits.
    static let twoColumnWidth = 3 * thumbnailMinimum + 2 * spacing + 2 * padding - 1
}

nonisolated struct BrowserEntry: Identifiable, Sendable {
    let url: URL
    let isFolder: Bool
    var hasSavedSettings = false
    var isRAW = false
    var id: URL { url }
}

nonisolated enum BrowserFileFilter: String {
    case all, raw, edited
}

@Observable
@MainActor
final class ImageBrowserModel {
    var root: URL?
    var directory: URL?
    var entries: [BrowserEntry] = []
    var filter = BrowserFileFilter.all
    var pendingURLs: Set<URL> = []
    var visibleFiles: [BrowserEntry] {
        entries.filter {
            guard !$0.isFolder else { return false }
            switch filter {
            case .all: return true
            case .raw: return $0.isRAW
            case .edited: return $0.hasSavedSettings || pendingURLs.contains($0.url.standardizedFileURL)
            }
        }
    }
    var batchFiles: [BrowserEntry] {
        let files = visibleFiles
        return files.filter(\.hasSavedSettings) + files.filter { !$0.hasSavedSettings }
    }
    var folderCounts: [URL: Int] = [:]
    private(set) var recentFolders: [URL: [URL]] = [:]
    var error: String?
    var loading = false
    private(set) var listingRevision = UUID()
    private(set) var returnFolder: URL?
    private var access: [URL] = []
    private var listing: Task<Void, Never>?

    func choose(_ url: URL) {
        if !access.contains(url), url.startAccessingSecurityScopedResource() { access.append(url) }
        root = url
        navigate(to: url)
    }
    func navigate(to url: URL) {
        let parent = url.standardizedFileURL
        returnFolder = nil
        if let previous = directory?.standardizedFileURL,
           previous != parent, previous.deletingLastPathComponent() == parent {
            returnFolder = previous
            var recent = recentFolders[parent, default: []]
            recent.removeAll { $0 == previous }
            recent.insert(previous, at: 0)
            recentFolders[parent] = Array(recent.prefix(3))
        }
        listing?.cancel()
        directory = url
        entries = []
        folderCounts = [:]
        error = nil
        loading = true
        listing = Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .contentTypeKey]
                    let urls = try FileManager.default.contentsOfDirectory(at: url,
                        includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
                    // Reuse the directory listing rather than doing a network
                    // existence check for every thumbnail on NAS volumes.
                    let names = Set(urls.map(\.lastPathComponent))
                    return try urls.compactMap { item -> BrowserEntry? in
                        try Task.checkCancellation()
                        let values = try item.resourceValues(forKeys: keys)
                        let folder = values.isDirectory == true && values.isPackage != true
                        guard folder || values.contentType?.conforms(to: .image) == true else { return nil }
                        return BrowserEntry(url: item, isFolder: folder,
                            hasSavedSettings: !folder && names.contains(RecipeStore.sidecarURL(for: item).lastPathComponent),
                            isRAW: values.contentType?.conforms(to: .rawImage) == true)
                    }.sorted {
                        if $0.isFolder != $1.isFolder { return $0.isFolder }
                        return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
                    }
                }.value
                try Task.checkCancellation()
                entries = result
                listingRevision = UUID()
                loading = false
                // Show the directory immediately; fill counts without blocking navigation.
                for entry in result where entry.isFolder {
                    try Task.checkCancellation()
                    let count = await Task.detached(priority: .utility) {
                        Self.imageCount(in: entry.url)
                    }.value
                    try Task.checkCancellation()
                    folderCounts[entry.url] = count
                }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
                loading = false
            }
        }
    }
    func refreshSavedSettingsFlag(for url: URL) {
        guard let index = entries.firstIndex(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) else { return }
        entries[index].hasSavedSettings = FileManager.default.fileExists(atPath: RecipeStore.sidecarURL(for: url).path)
    }
    nonisolated private static func imageCount(in folder: URL) -> Int {
        do {
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentTypeKey]
            let children = try FileManager.default.contentsOfDirectory(at: folder,
                includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
            return try children.reduce(0) { total, url in
                let values = try url.resourceValues(forKeys: keys)
                return total + (values.isRegularFile == true && values.contentType?.conforms(to: .image) == true ? 1 : 0)
            }
        } catch { return -1 }
    }

    isolated deinit {
        listing?.cancel()
        for url in access { url.stopAccessingSecurityScopedResource() }
    }
}

struct ImageFileBrowser: View {
    let selectedURL: URL?
    let open: (URL) -> Void
    var model: ImageBrowserModel
    var selection: Binding<Set<URL>>? = nil
    var changeDirectory: ((URL, Bool) -> Void)? = nil
    var fileAction: ((BrowserFileAction, URL) -> Void)? = nil
    var multipleFileAction: ((BrowserFileAction, [URL]) -> Void)? = nil
    var hasPendingEdit: ((URL) -> Bool)? = nil
    @State private var centeredOnOpen = false
    @State private var choosingFolder = false
    @State private var selectedFiles: Set<URL> = []
    @State private var selectionAnchor: URL?

    private var activeSelection: Set<URL> { selection?.wrappedValue ?? selectedFiles }
    private func selectFile(_ url: URL, ordered: [URL]) {
        var selected = activeSelection
        #if os(macOS)
        let flags = NSEvent.modifierFlags
        let command = flags.contains(.command), shift = flags.contains(.shift)
        if selection == nil, selectionAnchor == nil, let selectedURL, ordered.contains(selectedURL) {
            selected.insert(selectedURL)
        }
        if shift, let anchor = selectionAnchor ?? selectedURL,
           let a = ordered.firstIndex(of: anchor), let b = ordered.firstIndex(of: url) {
            let range = Set(ordered[min(a,b)...max(a,b)])
            selected = command ? selected.union(range) : range
        } else if command {
            if selected.contains(url) { selected.remove(url) } else { selected.insert(url) }
            selectionAnchor = url
        } else {
            selected = [url]; selectionAnchor = url
        }
        if let selection { selection.wrappedValue = selected } else { selectedFiles = selected }
        if selection == nil && !command && !shift { open(url) }
        #else
        if let selection {
            if selected.contains(url) { selected.remove(url) } else { selected.insert(url) }
            selection.wrappedValue = selected
        } else { selectedFiles = [url]; open(url) }
        #endif
    }

    private func contextFiles(_ url: URL, ordered: [URL]) -> [URL] {
        activeSelection.contains(url) ? ordered.filter { activeSelection.contains($0) } : [url]
    }


    private func navigate(_ url: URL, choose: Bool = false) {
        if let changeDirectory { changeDirectory(url, choose) }
        else if choose { model.choose(url) }
        else { model.navigate(to: url) }
    }

    var body: some View {
        // Read observable collections here, not inside deferred lazy-container
        // builders. Async listings must invalidate this view even when the first
        // layout happened while the directory was still empty.
        let entries = model.entries
        let pendingURLs = Set(entries.filter { !$0.isFolder && (hasPendingEdit?($0.url) ?? false) }.map { $0.url.standardizedFileURL })
        let folders = selection == nil ? entries.filter(\.isFolder) : []
        let visible = model.filter == .edited
            ? entries.filter { !$0.isFolder && ($0.hasSavedSettings || pendingURLs.contains($0.url.standardizedFileURL)) }
            : model.visibleFiles
        let files = selection == nil ? visible : visible.filter(\.hasSavedSettings) + visible.filter { !$0.hasSavedSettings }
        let folderCounts = model.folderCounts
        let listingRevision = model.listingRevision
        let returnFolder = model.returnFolder
        let recent = model.directory.map { model.recentFolders[$0.standardizedFileURL, default: []] } ?? []
        VStack(spacing: 0) {
            HStack {
                Text("Files").font(.headline)
                Spacer()
                Button("Choose Folder…", systemImage: "folder.badge.plus") { choosingFolder = true }
                    .labelStyle(.iconOnly)
                    .disabled(selection != nil)
            }
            .padding(12)
            if let directory = model.directory {
                HStack {
                    Button("Up", systemImage: "chevron.up") {
                        navigate(directory.deletingLastPathComponent())
                    }
                    .labelStyle(.iconOnly)
                    .disabled(selection != nil || directory.standardizedFileURL == model.root?.standardizedFileURL)
                    Text(directory.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        .help(directory.path)
                    Spacer()
                    Button("Refresh", systemImage: "arrow.clockwise") { model.navigate(to: directory) }
                        .labelStyle(.iconOnly)
                }
                .padding(.horizontal, 12).padding(.bottom, 8)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 4) {
                            LazyVStack(spacing: 4) {
                                ForEach(folders) { entry in
                                    let rank = recent.firstIndex(of: entry.url.standardizedFileURL)
                                    let warmth: Color = rank == 0 ? .orange : rank == 1 ? .yellow : .cyan
                                    Button { navigate(entry.url) } label: {
                                        HStack {
                                            Image(systemName: "folder")
                                                .foregroundStyle(rank == nil ? Color.secondary : warmth.opacity(rank == 0 ? 1 : rank == 1 ? 0.65 : 0.4))
                                            Text(entry.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                            Spacer(minLength: 0)
                                            if let count = folderCounts[entry.url] {
                                                Text(count >= 0 ? "\(count)" : "—")
                                                    .monospacedDigit().foregroundStyle(.secondary)
                                                    .help("Image files directly in this folder")
                                            } else {
                                                Text("…").foregroundStyle(.secondary)
                                            }
                                        }
                                        .padding(6)
                                        .background(rank == nil ? Color.clear : warmth.opacity(rank == 0 ? 0.22 : rank == 1 ? 0.11 : 0.045),
                                                    in: RoundedRectangle(cornerRadius: 5))
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .id(entry.url.standardizedFileURL)
                                    .accessibilityValue(rank.map { "Recently visited folder, \($0 + 1) of \(recent.count)" } ?? "")
                                }
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: BrowserGridLayout.thumbnailMinimum), spacing: BrowserGridLayout.spacing)], spacing: BrowserGridLayout.spacing) {
                                ForEach(files) { entry in
                                    Button {
                                        selectFile(entry.url, ordered: files.map(\.url))
                                    } label: {
                                        FileThumbnail(url: entry.url)
                                            .padding(4)
                                            .background((activeSelection.contains(entry.url) || (selectionAnchor == nil && activeSelection.isEmpty && selectedURL == entry.url)) ? Color.accentColor.opacity(0.25) : .clear,
                                                        in: RoundedRectangle(cornerRadius: 6))
                                            .overlay {
                                                if entry.hasSavedSettings {
                                                    RoundedRectangle(cornerRadius: 6)
                                                        .strokeBorder(Color.accentColor, lineWidth: 1.5)
                                                        .allowsHitTesting(false)
                                                }
                                            }

                                    }
                                    .id(entry.url.standardizedFileURL)
                                    .buttonStyle(.plain)
                                    .help(entry.url.lastPathComponent + (entry.hasSavedSettings ? " · " + String(localized: "Saved development settings") : ""))
                                    .accessibilityValue(entry.hasSavedSettings ? "Saved development settings" : "")
                                    .contextMenu {
                                        if let fileAction {
                                            let targets = contextFiles(entry.url, ordered: files.map(\.url))
                                            Button(targets.count > 1 ? "Delete Edits (\(targets.count))" : "Delete Edit", role: .destructive) {
                                                if let multipleFileAction { multipleFileAction(.deleteEdit, targets) }
                                                else { fileAction(.deleteEdit, entry.url) }
                                            }
                                            .disabled(!files.contains { targets.contains($0.url) && ($0.hasSavedSettings || (hasPendingEdit?($0.url) ?? false)) })
                                            #if os(macOS)
                                            Button("Show in Finder") { fileAction(.showInFinder, entry.url) }
                                            #endif
                                            Divider()
                                            Button("Copy Edit") { fileAction(.copyEdit, entry.url) }
                                            Button(targets.count > 1 ? "Paste Edit to \(targets.count) Files…" : "Paste Edit…") {
                                                if let multipleFileAction { multipleFileAction(.pasteEdit, targets) }
                                                else { fileAction(.pasteEdit, entry.url) }
                                            }
                                            Divider()
                                            Button("Export…") { fileAction(.export, entry.url) }
                                        }
                                    }
                                }
                            }
                        }
                        .padding(BrowserGridLayout.padding)
                        .frame(maxWidth: .infinity)
                    }
                    .task(id: listingRevision) {
                        let current = selectedURL?.standardizedFileURL
                        let target: URL?
                        if !centeredOnOpen, let current,
                           files.contains(where: { $0.url.standardizedFileURL == current }) {
                            target = current
                        } else if let returnFolder,
                                  folders.contains(where: { $0.url.standardizedFileURL == returnFolder }) {
                            target = returnFolder
                        } else { target = nil }
                        guard !model.loading else { return }
                        centeredOnOpen = true
                        guard let target else { return }
                        // Let the newly mounted lazy rows register their scroll IDs.
                        await Task.yield()
                        guard !Task.isCancelled else { return }
                        proxy.scrollTo(target, anchor: .center)
                    }
                }
                // Recreate the scroll layout when an async listing arrives after
                // an empty first layout. Counts/thumbnails do not reset scrolling.
                .id(listingRevision)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if model.loading { ProgressView() }
                    else if let error = model.error { Text(error).font(.caption).padding() }
                    else if files.isEmpty && folders.isEmpty { Text(model.filter == .raw ? "No RAW images" : model.filter == .edited ? "No edited images" : "No images").foregroundStyle(.secondary) }
                }
            } else {
                Spacer()
                Button("Choose Folder…") { choosingFolder = true }
                Text("Browse images and subfolders.")
                    .font(.caption).foregroundStyle(.secondary).padding(8)
                Spacer()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Picker("File filter", selection: Binding(get: { model.filter }, set: { value in
                    model.filter = value
                    let visible = Set(model.visibleFiles.map(\.url))
                    selectedFiles.formIntersection(visible)
                    if let selection { selection.wrappedValue.formIntersection(visible) }
                    selectionAnchor = nil
                })) {
                    Text("ALL").tag(BrowserFileFilter.all)
                    Text("RAW").tag(BrowserFileFilter.raw)
                    Text("Edited").tag(BrowserFileFilter.edited)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Spacer()
            }
            .padding(10)
            .background(.bar)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.bar)
        .onChange(of: pendingURLs, initial: true) { _, urls in
            model.pendingURLs = urls
        }
        .onReceive(NotificationCenter.default.publisher(for: .developmentSettingsChanged)
            .receive(on: DispatchQueue.main)) { notification in
            if let url = notification.object as? URL { model.refreshSavedSettingsFlag(for: url) }
        }
        .onChange(of: model.directory) { _, _ in
            selectedFiles.removeAll(); selectionAnchor = nil
            selection?.wrappedValue.removeAll()
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): navigate(url, choose: true)
            case .failure(let error): model.error = error.localizedDescription
            }
        }
    }
}

struct EditorColumns<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        #if os(macOS)
        HSplitView { content }
        #else
        HStack(spacing: 0) { content }
        #endif
    }
}

private struct FileThumbnail: View {
    let url: URL
    @State private var image: CGImage?

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Color.black.opacity(0.15)
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable().scaledToFit()
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(url.lastPathComponent)
                .font(.caption).lineLimit(1).truncationMode(.middle)
        }
        .task(id: url) {
            image = nil
            let result = await BrowserThumbnails.shared.thumbnail(for: url)
            guard !Task.isCancelled else { return }
            image = result
        }
    }
}

// Serialize decoding off the main actor and bound the cache for large folders.
private actor BrowserThumbnails {
    static let shared = BrowserThumbnails()
    private let cache = NSCache<NSURL, CGImage>()

    init() { cache.totalCostLimit = 32 * 1024 * 1024 }

    func thumbnail(for url: URL) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        if let image = cache.object(forKey: url as NSURL) { return image }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 256,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        cache.setObject(image, forKey: url as NSURL, cost: image.bytesPerRow * image.height)
        return image
    }
}
