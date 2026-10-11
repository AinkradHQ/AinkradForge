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
    private(set) var tabs = Tabs()
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

    var unsavedPaths: [String] { tabs.paths.filter { documents[$0]?.isDirty == true } }

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
        tabs = saved.tabs
        expanded = saved.expanded
        recentFiles = saved.recentFiles ?? []
        store.noteOpened(key)
        await workspace.refresh()
        // Tabs whose files are gone since last time are dropped.
        for path in tabs.paths where !FileManager.default.fileExists(atPath: workspace.url(for: path).path(percentEncoded: false)) {
            tabs.close(path)
        }
        loadActive()
        persist()
    }

    private func closeWorkspace() {
        persist()
        workspace = nil
        documents = [:]
        tabs = Tabs()
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
        if let replaced, !tabs.paths.contains(replaced) { documents[replaced] = nil }
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
        documents[path] = nil
        loadActive()
        persist()
    }

    /// Loads the active tab's file the first time it is shown. Never from a view body: it writes state.
    private func loadActive() {
        guard let path = tabs.active, documents[path] == nil, let workspace else { return }
        let document = EditorDocument(url: workspace.url(for: path))
        documents[path] = document
        Task { await document.load() }
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

    private func persist() {
        guard let key = workspace?.root.path(percentEncoded: false) else { return }
        let state = ForgeDocument.WorkspaceState(tabs: tabs, expanded: expanded, recentFiles: recentFiles)
        store.update { $0.workspaces[key] = state }
    }
}
