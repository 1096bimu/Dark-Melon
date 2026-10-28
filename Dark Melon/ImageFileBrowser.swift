import SwiftUI
import Combine
import UniformTypeIdentifiers
import Observation
import ImageIO
#if os(macOS)
import AppKit
#endif

nonisolated enum BrowserGridLayout {
    static let spacing: CGFloat = 8
    static let padding: CGFloat = 8
    // Three discrete layouts. Image/editor updates never resize a thumbnail.
    static func cellWidth(columns: Int) -> CGFloat {
        switch columns {
        case 1: 160
        case 2: 112
        default: 88
        }
    }
    static func minimumWidth(columns: Int) -> CGFloat {
        CGFloat(columns) * cellWidth(columns: columns)
            + CGFloat(columns - 1) * spacing + 2 * padding
    }
    static let batchCellWidth: CGFloat = 112
    static func batchColumnCount(for width: CGFloat, current: Int) -> Int {
        guard width.isFinite else { return 1 }
        let stride = batchCellWidth + spacing
        let available = width - 2 * padding + spacing
        let lower = max(1, Int(((available - 4) / stride).rounded(.down)))
        let upper = max(1, Int(((available + 4) / stride).rounded(.down)))
        return min(upper, max(lower, current))
    }

    static let twoColumnWidth = minimumWidth(columns: 3) - 1

    static func columnCount(for viewportWidth: CGFloat, current: Int) -> Int {
        guard viewportWidth.isFinite else { return 1 }
        var count = min(3, max(1, current))
        // Keep a small dead band at each transition for split-view rounding.
        while count < 3, viewportWidth >= minimumWidth(columns: count + 1) + 4 { count += 1 }
        while count > 1, viewportWidth < minimumWidth(columns: count) - 4 { count -= 1 }
        return count
    }
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
            case .edited: return $0.hasSavedSettings || pendingURLs.contains($0.url)
            }
        }
    }
    /// Follow the displayed filter/order, stop at either end, and skip folders.
    func adjacentFile(to current: URL?, direction: Int) -> URL? {
        guard !loading, direction == -1 || direction == 1 else { return nil }
        let files = visibleFiles
        guard !files.isEmpty else { return nil }
        guard let current, let index = files.firstIndex(where: { $0.url == current.standardizedFileURL }) else {
            return direction > 0 ? files.first?.url : files.last?.url
        }
        let next = index + direction
        return files.indices.contains(next) ? files[next].url : nil
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

    private let remembersFolder: Bool
    private var restoreStarted = false
    private var restoreID: UUID?
    private var restoreTimeout: Task<Void, Never>?
    private var bookmarkRevision = UUID()
    private static let bookmarkKey = "browser.lastFolderBookmarks"
    init(remembersFolder: Bool = false) { self.remembersFolder = remembersFolder }

    private func rememberFolder() {
        guard remembersFolder, let root, let directory else { return }
        let revision = UUID()
        bookmarkRevision = revision
        Task {
            let data = await Task.detached(priority: .utility) { () -> Data? in
                #if os(macOS)
                let options: URL.BookmarkCreationOptions = [.withSecurityScope]
                #else
                let options: URL.BookmarkCreationOptions = []
                #endif
                guard let rootData = try? root.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil),
                      let directoryData = try? directory.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil) else { return nil }
                return try? PropertyListEncoder().encode([rootData, directoryData])
            }.value
            guard bookmarkRevision == revision, let data else { return }
            UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
        }
    }

    func restoreLastFolder() {
        guard remembersFolder, !restoreStarted else { return }
        restoreStarted = true
        guard directory == nil,
              let data = UserDefaults.standard.data(forKey: Self.bookmarkKey),
              let bookmarks = try? PropertyListDecoder().decode([Data].self, from: data), bookmarks.count == 2 else { return }
        let id = UUID()
        restoreID = id
        restoreTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, self.restoreID == id else { return }
            self.abandonRestoration()
        }
        Task {
            let resolved = await Task.detached(priority: .utility) { () -> (URL, URL, [URL])? in
                #if os(macOS)
                let options: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI, .withoutMounting]
                #else
                let options: URL.BookmarkResolutionOptions = [.withoutUI, .withoutMounting]
                #endif
                var stale = false
                guard let root = try? URL(resolvingBookmarkData: bookmarks[0], options: options, relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
                var access: [URL] = []
                if root.startAccessingSecurityScopedResource() { access.append(root) }
                guard let directory = try? URL(resolvingBookmarkData: bookmarks[1], options: options, relativeTo: nil, bookmarkDataIsStale: &stale) else {
                    for url in access { url.stopAccessingSecurityScopedResource() }
                    return nil
                }
                if directory != root, directory.startAccessingSecurityScopedResource() { access.append(directory) }
                return (root, directory, access)
            }.value
            guard restoreID == id else {
                if let resolved { for url in resolved.2 { url.stopAccessingSecurityScopedResource() } }
                return
            }
            guard let resolved else { abandonRestoration(); return }
            access.append(contentsOf: resolved.2)
            root = resolved.0
            navigate(to: resolved.1, restoring: true)
        }
    }
    private func abandonRestoration() {
        restoreID = nil
        restoreTimeout?.cancel()
        listing?.cancel()
        root = nil; directory = nil; entries = []; folderCounts = [:]
        loading = false; error = nil
        for url in access { url.stopAccessingSecurityScopedResource() }
        access = []
    }

    func choose(_ url: URL) {
        if !access.contains(url), url.startAccessingSecurityScopedResource() { access.append(url) }
        root = url
        navigate(to: url)
    }
    func navigate(to url: URL, restoring: Bool = false) {
        if !restoring {
            restoreID = nil
            restoreTimeout?.cancel()
        }
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
        if !restoring { rememberFolder() }
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
                        return BrowserEntry(url: item.standardizedFileURL, isFolder: folder,
                            hasSavedSettings: !folder && names.contains(RecipeStore.sidecarURL(for: item).lastPathComponent),
                            isRAW: values.contentType?.conforms(to: .rawImage) == true)
                    }.sorted {
                        if $0.isFolder != $1.isFolder { return $0.isFolder }
                        return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
                    }
                }.value
                try Task.checkCancellation()
                if restoring {
                    restoreID = nil
                    restoreTimeout?.cancel()
                    rememberFolder()
                }
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
                if restoring { abandonRestoration(); return }
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
        restoreTimeout?.cancel()
        for url in access { url.stopAccessingSecurityScopedResource() }
    }
}

struct ImageFileBrowser: View {
    let selectedURL: URL?
    let open: (URL) -> Void
    var model: ImageBrowserModel
    var selection: Binding<Set<URL>>? = nil
    var expandedGrid = false
    var changeDirectory: ((URL, Bool) -> Void)? = nil
    var fileAction: ((BrowserFileAction, URL) -> Void)? = nil
    var multipleFileAction: ((BrowserFileAction, [URL]) -> Void)? = nil
    var pendingURLs: Set<URL> = []
    @State private var centeredOnOpen = false
    @State private var choosingFolder = false
    @State private var selectedFiles: Set<URL> = []
    @State private var selectionAnchor: URL?
    @State private var gridColumnCount = 2

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
        let folders = selection == nil ? entries.filter(\.isFolder) : []
        let visible = model.filter == .edited
            ? entries.filter { !$0.isFolder && ($0.hasSavedSettings || pendingURLs.contains($0.url)) }
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
                    GeometryReader { viewport in
                        let cellWidth = expandedGrid ? BrowserGridLayout.batchCellWidth : BrowserGridLayout.cellWidth(columns: gridColumnCount)
                        ScrollView {
                            VStack(spacing: 4) {
                                LazyVStack(spacing: 4) {
                                    ForEach(folders) { entry in
                                        let rank = recent.firstIndex(of: entry.url)
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
                                        .id(entry.url)
                                        .accessibilityValue(rank.map { "Recently visited folder, \($0 + 1) of \(recent.count)" } ?? "")
                                    }
                                }
                                // Fixed cells do not stretch with scrollbars or parent layout updates.
                                LazyVGrid(columns: Array(repeating: GridItem(.fixed(cellWidth), spacing: BrowserGridLayout.spacing), count: gridColumnCount), spacing: BrowserGridLayout.spacing) {
                                    ForEach(files) { entry in
                                        Button {
                                            selectFile(entry.url, ordered: files.map(\.url))
                                        } label: {
                                            FileThumbnail(url: entry.url, imageWidth: max(1, cellWidth - 8))
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
                                        .id(entry.url)
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
                                                .disabled(!files.contains { targets.contains($0.url) && ($0.hasSavedSettings || pendingURLs.contains($0.url)) })
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
                            .frame(width: viewport.size.width)
                        }
                        .onChange(of: viewport.size.width.rounded(.down), initial: true) { _, width in
                            let count = expandedGrid
                                ? BrowserGridLayout.batchColumnCount(for: width, current: gridColumnCount)
                                : BrowserGridLayout.columnCount(for: width, current: gridColumnCount)
                            if count != gridColumnCount { gridColumnCount = count }
                        }
                        .onChange(of: selectedURL) { _, url in
                            guard selection == nil, let url else { return }
                            let key = url.standardizedFileURL
                            guard files.contains(where: { $0.url == key }) else { return }
                            proxy.scrollTo(key, anchor: .center)
                        }
                        .task(id: listingRevision) {
                            let current = selectedURL?.standardizedFileURL
                            let target: URL?
                            if !centeredOnOpen, let current,
                               files.contains(where: { $0.url == current }) {
                                target = current
                            } else if let returnFolder,
                                      folders.contains(where: { $0.url == returnFolder }) {
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
        #if os(macOS)
        .background(BrowserSelectAllShortcut {
            let urls = files.map(\.url)
            if let selection { selection.wrappedValue = Set(urls) }
            else { selectedFiles = Set(urls) }
            selectionAnchor = urls.first
        }.frame(width: 0, height: 0))
        #endif
        .onChange(of: pendingURLs, initial: true) { _, urls in
            model.pendingURLs = urls
        }
        .onReceive(NotificationCenter.default.publisher(for: .developmentSettingsChanged)
            .receive(on: DispatchQueue.main)) { notification in
            if let url = notification.object as? URL { model.refreshSavedSettingsFlag(for: url) }
        }
        .onChange(of: selectedURL) { _, url in
            guard selection == nil, selectedFiles.count <= 1 else { return }
            selectedFiles = url.map { [$0] } ?? []
            selectionAnchor = url
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
    let imageWidth: CGFloat
    @State private var image: CGImage?

    var body: some View {
        VStack(spacing: 4) {
            Color.black.opacity(0.15)
                .frame(width: imageWidth, height: imageWidth)
                .overlay {
                    // Loading an image must not change the square's layout size.
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable().scaledToFit()
                    } else {
                        Image(systemName: "photo").foregroundStyle(.secondary)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(url.lastPathComponent)
                .font(.caption).lineLimit(1).truncationMode(.middle)
                .frame(width: imageWidth)
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
