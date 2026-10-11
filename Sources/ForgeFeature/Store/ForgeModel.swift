import AinkradAppKit
import Foundation
import Observation

/// The window's state: which workspace is open, its tabs and documents, and the sidebar.
@MainActor
@Observable
final class ForgeModel {
    enum SideTab: String, CaseIterable, Identifiable {
        case files = "Files", changes = "Changes", search = "Search", problems = "Problems"
        var id: String { rawValue }
    }

    let store: ForgeStore
    /// Opens other Ainkrad apps (Rune for a terminal). `nil` in tests.
    let apps: PluginAppLauncher?
    private(set) var workspace: Workspace?
    /// The palette, open with this starting text: "" = files, ">" = commands, ":" = go to line.
    var palette: String?
    /// A line for the active editor to jump to, consumed by the editor.
    var pendingLine: Int?
    /// Newest first, for ⌘P.
    private(set) var recentFiles: [String] = []
    /// Shown as a toast: a failed save, or an app that would not open.
    var notice: String?
    var sideTab: SideTab = .files
    /// One editor pane, or two side by side (or stacked). Each has its own tabs.
    private(set) var panes: [Tabs] = [Tabs()]
    /// The pane keyboard commands and the palette act on.
    var activePane = 0
    /// Two panes stack top to bottom instead of side by side.
    var stacked = false
    /// The active pane's tabs.
    private(set) var tabs: Tabs {
        get { panes[min(activePane, panes.count - 1)] }
        set { panes[min(activePane, panes.count - 1)] = newValue }
    }
    private(set) var expanded: Set<String> = []
    private(set) var documents: [String: EditorDocument] = [:]
    /// A dirty tab the user asked to close: the window asks Save / Don't Save / Cancel.
    var pendingClose: String?
    /// Leaving the workspace (open another, or close it) while files are unsaved: the window asks first.
    var pendingLeave: Leave?

    enum Leave: Equatable {
        case open(URL)
        case close
    }

    /// Every open path once, across panes.
    var openPaths: [String] { panes.flatMap(\.paths).reduce(into: []) { if !$0.contains($1) { $0.append($1) } } }
    var unsavedPaths: [String] { openPaths.filter { documents[$0]?.isDirty == true } }

    init(store: ForgeStore, apps: PluginAppLauncher? = nil) {
        self.store = store
        self.apps = apps
    }

    /// Opens what another app asked for (`launch`: a folder, or a file — its folder, with the file in a tab);
    /// otherwise reopens the last workspace, if its folder still exists.
    func start(launch: String? = nil) async {
        // Other apps send an `AinkradLaunchIntent` (openDocument / openDirectory); a bare path works too.
        let launch = launch.flatMap { AinkradLaunchIntent.decode($0)?.path ?? $0 }
        var isFolder: ObjCBool = false
        if let launch, FileManager.default.fileExists(atPath: launch, isDirectory: &isFolder) {
            let url = URL(fileURLWithPath: launch)
            let folder = isFolder.boolValue ? url : url.deletingLastPathComponent()
            // A file opens its whole repo, when it is in one.
            let top = isFolder.boolValue ? nil : (try? await Git(directory: folder).run(["rev-parse", "--show-toplevel"]))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            await open(folder: top.map { URL(fileURLWithPath: $0) } ?? folder)
            if !isFolder.boolValue, let path = workspace?.relativePath(of: url) {
                reveal(path)
                open(file: path, pinned: true)
            }
            return
        }
        guard workspace == nil, let path = store.document.lastWorkspace,
            FileManager.default.fileExists(atPath: path)
        else { return }
        await open(folder: URL(fileURLWithPath: path))
    }

    // MARK: - Workspace

    /// Opens `folder` — or, with unsaved files, asks first.
    func request(_ leave: Leave) {
        if unsavedPaths.isEmpty {
            perform(leave)
        } else {
            pendingLeave = leave
        }
    }

    /// The answer to `pendingLeave`: save everything, discard, or (`nil`) stay.
    func resolvePendingLeave(saveAll: Bool?) {
        guard let leave = pendingLeave else { return }
        pendingLeave = nil
        switch saveAll {
        case true?:
            for path in unsavedPaths {
                do { try documents[path]?.save() } catch {
                    notice = "Could not save \(path): \(error.localizedDescription)"
                    return
                }
            }
            perform(leave)
        case false?: perform(leave)
        case nil: break
        }
    }

    private func perform(_ leave: Leave) {
        switch leave {
        case .open(let url): Task { await open(folder: url) }
        case .close: closeWorkspace()
        }
    }

    private func open(folder: URL) async {
        let workspace = Workspace(root: folder)
        let key = workspace.root.path(percentEncoded: false)
        self.workspace = workspace
        documents = [:]
        let saved = store.document.workspaces[key] ?? .init()
        panes = (saved.panes?.isEmpty == false ? saved.panes : nil) ?? [saved.tabs]
        activePane = min(saved.activePane ?? 0, panes.count - 1)
        stacked = saved.stacked ?? false
        expanded = saved.expanded
        recentFiles = saved.recentFiles ?? []
        store.noteOpened(key)
        await workspace.refresh()
        // Tabs whose files are gone since last time are dropped.
        for index in panes.indices {
            for path in panes[index].paths
            where !FileManager.default.fileExists(atPath: workspace.url(for: path).path(percentEncoded: false)) {
                panes[index].close(path)
            }
        }
        collapseEmptyPanes()
        loadActive()
        persist()
    }

    private func closeWorkspace() {
        persist()
        workspace = nil
        documents = [:]
        panes = [Tabs()]
        activePane = 0
        store.update { $0.lastWorkspace = nil }
    }

    // MARK: - Tabs

    var activeDocument: EditorDocument? { tabs.active.flatMap { documents[$0] } }

    /// Single click = preview; double click (or `pinned`) keeps the tab.
    func open(file path: String, pinned: Bool) {
        let replaced = tabs.preview
        tabs.open(path, pinned: pinned)
        recentFiles.removeAll { $0 == path }
        recentFiles.insert(path, at: 0)
        recentFiles = Array(recentFiles.prefix(30))
        if let replaced, !openPaths.contains(replaced) { documents[replaced] = nil }
        loadActive()
        persist()
    }

    func activate(_ path: String) {
        tabs.activate(path)
        loadActive()
        persist()
    }

    func pin(_ path: String) {
        tabs.pin(path)
        persist()
    }

    /// Closes a tab, asking first when it has unsaved changes.
    func close(_ path: String) {
        if documents[path]?.isDirty == true {
            pendingClose = path
        } else {
            discard(path)
        }
    }

    /// The answer to `pendingClose`: save then close, close without saving, or (`nil`) keep it open.
    func resolvePendingClose(save: Bool?) {
        guard let path = pendingClose else { return }
        pendingClose = nil
        switch save {
        case true?:
            guard let document = documents[path] else { return discard(path) }
            do {
                try document.save()
                discard(path)
                Task { await workspace?.refresh() }
            } catch {
                notice = "Could not save \(path): \(error.localizedDescription)"
            }
        case false?: discard(path)
        case nil: break
        }
    }

    private func discard(_ path: String) {
        tabs.close(path)
        // Another pane may still show it — the document (one buffer) stays while any tab does.
        if !openPaths.contains(path) { documents[path] = nil }
        collapseEmptyPanes()
        loadActive()
        persist()
    }

    /// Loads each pane's visible file the first time it is shown. Never from a view body: it writes state.
    func loadActive() {
        guard let workspace else { return }
        for path in panes.compactMap(\.active) where documents[path] == nil {
            let document = EditorDocument(url: workspace.url(for: path))
            documents[path] = document
            Task { await document.load() }
        }
    }

    func didEdit(_ path: String) {
        documents[path]?.didEdit()
        if tabs.preview == path { pin(path) }
    }

    func saveActive() {
        guard let path = tabs.active, let document = documents[path], document.isDirty else { return }
        do {
            try document.save()
            Task { await workspace?.refresh() }
        } catch {
            notice = "Could not save \(path): \(error.localizedDescription)"
        }
    }

    // MARK: - Tree

    /// Expands every folder above `path`, so its row is visible.
    func reveal(_ path: String) {
        var parts = path.split(separator: "/").dropLast()
        while !parts.isEmpty {
            expanded.insert(parts.joined(separator: "/"))
            parts = parts.dropLast()
        }
        persist()
    }

    func toggle(folder path: String) {
        if expanded.contains(path) { expanded.remove(path) } else { expanded.insert(path) }
        persist()
    }

    func persist() {
        guard let key = workspace?.root.path(percentEncoded: false) else { return }
        let state = ForgeDocument.WorkspaceState(
            tabs: panes[0], expanded: expanded, recentFiles: recentFiles, panes: panes, activePane: activePane,
            stacked: stacked)
        store.update { $0.workspaces[key] = state }
    }
}

/// The split editor: at most two panes, each with its own tabs, sharing one buffer per file.
extension ForgeModel {
    /// ⌘\ — a second pane showing the active file (one buffer, two views), or focus it if it exists.
    func splitEditor(stacked: Bool) {
        self.stacked = stacked
        if panes.count == 1 {
            var second = Tabs()
            if let path = tabs.active { second.open(path, pinned: true) }
            panes.append(second)
        }
        activePane = 1
        loadActive()
        persist()
    }

    /// The pane at `index` becomes the one commands act on (a click in its editor, or ⌘1 / ⌘2).
    func focus(pane index: Int) {
        guard panes.indices.contains(index), index != activePane else { return }
        activePane = index
        persist()
    }

    /// Closes the active pane; its tabs are dropped, unsaved ones kept open in the other pane first.
    func closePane() {
        guard panes.count > 1 else { return }
        let closing = activePane
        let other = 1 - closing
        for path in panes[closing].paths where documents[path]?.isDirty == true && !panes[other].paths.contains(path) {
            panes[other].open(path, pinned: true)
        }
        panes.remove(at: closing)
        activePane = 0
        for path in documents.keys where !openPaths.contains(path) { documents[path] = nil }
        loadActive()
        persist()
    }

    /// A pane whose last tab closed goes away, unless it is the only one.
    func collapseEmptyPanes() {
        panes.removeAll { $0.paths.isEmpty }
        if panes.isEmpty { panes = [Tabs()] }
        activePane = min(activePane, panes.count - 1)
    }
}
