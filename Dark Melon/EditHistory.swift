import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Settings only: rendered images never enter the undo stack.
@MainActor @Observable final class EditHistory {
    private final class FileHistory {
        let manager = UndoManager()
        var current: DevelopmentRecipe
        var before: DevelopmentRecipe?
        var session = SnapshotSession()
        var beforeSession: SnapshotSession?
        var name = "Edit"
        init(_ recipe: DevelopmentRecipe) {
            current = recipe
            manager.groupsByEvent = false
            manager.levelsOfUndo = 100
        }
    }
    private var files: [URL: FileHistory] = [:]
    private var active: URL?
    private var settle: Task<Void, Never>?
    var interacting = false
    var restore: ((DevelopmentRecipe) -> Void)?
    var captureSession: (() -> SnapshotSession)?
    var restoreSession: ((SnapshotSession) -> Void)?
    private(set) var revision = 0

    var canUndo: Bool { active.flatMap { files[$0] }.map { $0.before != nil || $0.manager.canUndo } ?? false }
    var canRedo: Bool { active.flatMap { files[$0] }.map { $0.before == nil && $0.manager.canRedo } ?? false }
    var undoTitle: String { active.flatMap { files[$0] }.map { $0.before == nil ? $0.manager.undoMenuItemTitle : String(localized: "Undo") + " " + $0.name } ?? String(localized: "Undo") }
    var redoTitle: String { active.flatMap { files[$0] }?.manager.redoMenuItemTitle ?? String(localized: "Redo") }

    func activate(_ url: URL, recipe: DevelopmentRecipe) {
        flush()
        active = url.standardizedFileURL
        if files[active!] == nil { files[active!] = FileHistory(recipe) }
        // Decode/default initialization is not a user edit.
        files[active!]?.current = recipe
        files[active!]?.session = captureSession?() ?? SnapshotSession()
        revision += 1
    }

    func record(_ url: URL, from before: DevelopmentRecipe, to after: DevelopmentRecipe, name: String) {
        let url = url.standardizedFileURL
        guard before != after else { return }
        if active == url { observe(after, name: name); flush(); return }
        let file = files[url] ?? FileHistory(before)
        files[url] = file
        file.current = after
        register(before, file: file, url: url, name: name)
        revision += 1
    }

    func remove(_ url: URL) {
        let url = url.standardizedFileURL
        files.removeValue(forKey: url)
        if active == url { settle?.cancel(); settle = nil; active = nil }
        revision += 1
    }

    func seed(_ recipe: DevelopmentRecipe) {
        guard let active, let file = files[active], file.before == nil else { return }
        file.current = recipe
        file.session = captureSession?() ?? SnapshotSession()
    }

    func observe(_ recipe: DevelopmentRecipe, name: String? = nil) {
        guard let active, let file = files[active] else { return }
        let session = captureSession?() ?? SnapshotSession()
        guard recipe != file.current || session != file.session else { return }
        if file.before == nil { file.beforeSession = file.session; file.before = file.current; file.name = name ?? Self.actionName(from: file.current, to: recipe) }
        file.current = recipe
        file.session = session
        revision += 1
        settle?.cancel()
        settle = Task { [weak self] in
            do {
                // Coalesce keyboard repeats and wait through pauses within a mouse drag.
                try await Task.sleep(for: .milliseconds(350))
                while self?.interacting == true {
                    try await Task.sleep(for: .milliseconds(50))
                }
                try Task.checkCancellation()
                self?.flush()
            } catch { }
        }
    }

    func flush() {
        settle?.cancel(); settle = nil
        guard let active, let file = files[active], let before = file.before else { return }
        file.before = nil
        let session = file.beforeSession ?? file.session
        file.beforeSession = nil
        if before != file.current || session != file.session { register(before, file: file, url: active, name: file.name, session: session) }
        revision += 1
    }

    private func register(_ recipe: DevelopmentRecipe, file: FileHistory, url: URL, name: String, session: SnapshotSession? = nil) {
        let savedSession = session ?? file.session
        let manager = file.manager
        let explicitGroup = !manager.isUndoing && !manager.isRedoing
        if explicitGroup { manager.beginUndoGrouping() }
        manager.registerUndo(withTarget: self) { [weak file] history in
            MainActor.assumeIsolated {
                guard let file else { return }
                history.register(file.current, file: file, url: url, name: name, session: file.session)
                file.current = recipe
                file.session = savedSession
                history.revision += 1
                if history.active == url { history.restoreSession?(savedSession); history.restore?(recipe) }
            }
        }
        manager.setActionName(name)
        if explicitGroup { manager.endUndoGrouping() }
    }

    func undo() { flush(); if let active { files[active]?.manager.undo() }; revision += 1 }
    func redo() { flush(); if let active { files[active]?.manager.redo() }; revision += 1 }
    func clear() { settle?.cancel(); settle = nil; files.removeAll(); active = nil; revision += 1 }

    static func actionName(from old: DevelopmentRecipe, to new: DevelopmentRecipe) -> String {
        if old.colorSpace != new.colorSpace { return String(localized: "Color space") }
        if old.rawSettings != new.rawSettings { return String(localized: "RAW") }
        let a = old.mapping, b = new.mapping
        if a.transform != b.transform { return String(localized: "Transform") }
        if a.whiteBalance != b.whiteBalance || a.rawWhiteBalance != b.rawWhiteBalance { return String(localized: "White Balance") }
        if a.color != b.color { return String(localized: "Color") }
        if a.vertexWarp != b.vertexWarp || a.hls != b.hls || a.blackAndWhite != b.blackAndWhite { return String(localized: "Color") }
        if a.vignette != b.vignette || a.clarity != b.clarity || a.hdf != b.hdf || a.grain != b.grain || a.halation != b.halation || a.clarityRadius != b.clarityRadius || a.hdfRadius != b.hdfRadius { return String(localized: "Effects") }
        if a.tonePosition != b.tonePosition { return String(localized: "Tone") }
        if a.offset != b.offset { return String(localized: "Offset") }
        if a.channelContrast != b.channelContrast { return String(localized: "Dye Response") }
        if a.concentration != b.concentration { return String(localized: "Contrast") }
        if a.white != b.white { return String(localized: "White point") }
        return String(localized: "Tone")
    }
}

struct EditorUndoActions {
    var canUndo: Bool
    var canRedo: Bool
    var undoTitle: String
    var redoTitle: String
    var undo: () -> Void
    var redo: () -> Void
}
private struct EditorUndoKey: FocusedValueKey { typealias Value = EditorUndoActions }
extension FocusedValues {
    var editorUndo: EditorUndoActions? {
        get { self[EditorUndoKey.self] }
        set { self[EditorUndoKey.self] = newValue }
    }
}

/// Passive input boundaries; native controls retain their own gestures and hit testing.
#if os(macOS)
struct EditGestureBoundary: NSViewRepresentable {
    var began: () -> Void
    var ended: () -> Void
    final class Observer: NSView {
        var began: () -> Void = {}
        var ended: () -> Void = {}
        var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> Observer {
        let view = Observer()
        view.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak view] event in
            if let view, event.window === view.window {
                if event.type == .leftMouseDown { view.began() }
                else { DispatchQueue.main.async { [weak view] in view?.ended() } }
            }
            return event
        }
        return view
    }
    func updateNSView(_ view: Observer, context: Context) { view.began = began; view.ended = ended }
    static func dismantleNSView(_ view: Observer, coordinator: ()) {
        if let monitor = view.monitor { NSEvent.removeMonitor(monitor) }
    }
}
#else
import UIKit
struct EditGestureBoundary: UIViewRepresentable {
    var began: () -> Void
    var ended: () -> Void
    final class TouchObserver: UIGestureRecognizer {
        var began: () -> Void = {}
        var ended: () -> Void = {}
        override func canPrevent(_ other: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by other: UIGestureRecognizer) -> Bool { false }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            if state == .possible { began(); state = .began }
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { state = .changed }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            state = .ended
            DispatchQueue.main.async { [weak self] in self?.ended() }
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            state = .cancelled
            DispatchQueue.main.async { [weak self] in self?.ended() }
        }
    }
    final class Observer: UIView {
        let touch = TouchObserver()
        override func didMoveToWindow() {
            super.didMoveToWindow()
            touch.view?.removeGestureRecognizer(touch)
            touch.cancelsTouchesInView = false
            touch.delaysTouchesBegan = false
            touch.delaysTouchesEnded = false
            window?.addGestureRecognizer(touch)
        }
    }
    func makeUIView(context: Context) -> Observer { Observer() }
    func updateUIView(_ view: Observer, context: Context) { view.touch.began = began; view.touch.ended = ended }
    static func dismantleUIView(_ view: Observer, coordinator: ()) { view.touch.view?.removeGestureRecognizer(view.touch) }
}
#endif
