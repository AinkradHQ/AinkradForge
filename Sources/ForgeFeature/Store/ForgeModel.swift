import AinkradAppKit
import AppKit
import ForgeEditor
import ForgeLanguage
import Foundation
import Observation

/// The window's state: which workspace is open, its tabs and documents, and the sidebar.
@MainActor
@Observable
final class ForgeModel {
    enum SideTab: String, CaseIterable, Identifiable {
        // "Issues" (Xcode's word) rather than "Problems", so all four fit one segmented control.
        case files = "Files", changes = "Changes", search = "Search", problems = "Issues"
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
    /// The hover card on screen, if any.
    var hover: HoverInfo?
    /// The hover asked for last; an answer for any other is stale and dropped.
    @ObservationIgnored var hoverRequest = 0
    /// The signature hint over the caret, while it is in a call.
    var signature: SignatureInfo?
    @ObservationIgnored var signatureRequest = 0
    /// The rename field, while open; a rename (or a server's edit) waiting in its preview.
    var rename: RenameState?
    var pendingEdit: PendingEdit?
    /// Edits for the editor showing each file to make (undoable there), and the code-action menu to open.
    var editorEdits: [String: EditorEdits] = [:]
    var actionMenu: EditorMenu?
    @ObservationIgnored var menuActions: [CodeActionItem] = []
    @ObservationIgnored var editSequence = 0
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
    private(set) var documents: [String: EditorDocument] = [:] {
        // A buffer that goes away (closed, renamed, trashed, workspace switched) is closed on its server too.
        didSet { for path in oldValue.keys where documents[path] == nil { languages.closed(path: path); git.closed(path); agent.closed(path, text: oldValue[path]?.storage.string) } }
    }
    /// The workspace's language servers: diagnostics now; hover, completion and the rest as E5 lands.
    let languages = LanguageHub()
    let terminals = TerminalDrawer()
    let git = EditorGit()
    let tasks = TaskRunner()
    let agent = AgentReview()
    /// A dirty tab the user asked to close: the window asks Save / Don't Save / Cancel.
    var pendingClose: String?
    /// Leaving the workspace (open another, or close it) while files are unsaved: the window asks first.
    var pendingLeave: Leave?
    /// Watches the workspace on disk: outside edits reach open buffers, the tree and git marks refresh.
    @ObservationIgnored private var watcher: FolderWatcher?
    /// The Search tab, one per window; cleared when another workspace opens.
    let search = SearchModel()
    /// Bumped to put the cursor in the search field (⌘⇧F).
    var searchFocusRequest = 0
    /// A name being typed in the tree: a rename, or a new file / folder in a folder ("" = the root).
    var treeEdit: TreeEdit?

    enum TreeEdit: Equatable {
        case rename(String)
        case newFile(in: String)
        case newFolder(in: String)
    }

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
        languages.onApplyEdit = { [weak self] changes in self?.apply(changes) ?? false }
        tasks.follow(terminals, model: self)
        // The host's quit prompt knows nothing of an app's unsaved files: keep them for the next launch instead.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.backupUnsaved() }
        }
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
        terminals.confirmLeaving { [weak self] in
            switch leave {
            case .open(let url): Task { await self?.open(folder: url) }
            case .close: self?.closeWorkspace()
            }
        }
    }

    private func open(folder: URL) async {
        let workspace = Workspace(root: folder)
        let key = workspace.root.path(percentEncoded: false)
        terminals.begin(root: workspace.root)
        git.reset()
        tasks.reset(); agent.reset()
        self.workspace = workspace
        documents = [:]
        let saved = store.document.workspaces[key] ?? .init()
        panes = (saved.panes?.isEmpty == false ? saved.panes : nil) ?? [saved.tabs]
        activePane = min(saved.activePane ?? 0, panes.count - 1)
        stacked = saved.stacked ?? false
        expanded = saved.expanded
        recentFiles = saved.recentFiles ?? []
        store.noteOpened(key)
        search.clear()
        beginLanguages(root: workspace.root)
        await workspace.refresh()
        await tasks.refresh(root: workspace.root, files: workspace.files)
        watcher = FolderWatcher(root: workspace.root) { [weak self] paths in
            guard paths.contains(where: FolderWatcher.isRelevant) else { return }
            Task { @MainActor in await self?.diskChanged(paths: paths) }
        }
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
        watcher = nil
        languages.end()
        terminals.end()
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
            document.onSaved = { [weak self] saved in
                guard let path = self?.workspace?.relativePath(of: saved.url) else { return }
                self?.languages.saved(path: path); self?.agent.wrote(path, text: saved.storage.string)
            }
            documents[path] = document
            Task {
                await document.load()
                if document.state == .ready {
                    restoreUnsaved(path, into: document)
                    languages.opened(path: path, text: document.storage.string)
                    loaded(path)
                }
            }
        }
    }

    func didEdit(_ path: String) {
        documents[path]?.didEdit()
        languages.changed(path: path) { [weak self] in self?.documents[path]?.storage.string ?? "" }
        bufferChanged(path)
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

/// File operations from the tree, the palette and Finder drops. Every path the window remembers follows a
/// rename or move: tabs in every pane, buffers (and the URL they save to), expanded folders, recents.
extension ForgeModel {
    /// The folder a new item goes into, for a row: a folder itself, else the file's folder.
    func folder(for path: String?, isDirectory: Bool) -> String {
        guard let path else { return "" }
        return isDirectory ? path : FileOps.parent(of: path)
    }

    /// Starts naming a new file or folder inside `folder`, opening it (and its parents) so the field shows.
    func beginNew(folder isFolder: Bool, in folder: String) {
        sideTab = .files
        if !folder.isEmpty {
            reveal(folder + "/x")
        }
        treeEdit = isFolder ? .newFolder(in: folder) : .newFile(in: folder)
    }

    /// Starts renaming `path` in the tree, revealing its row.
    func beginRename(_ path: String) {
        sideTab = .files
        reveal(path)
        treeEdit = .rename(path)
    }

    /// Ends the inline edit with `name` (from Return); the edit is simply dropped on Esc.
    func commitTreeEdit(_ name: String) {
        guard let edit = treeEdit, let root = workspace?.root else { return }
        treeEdit = nil
        perform {
            switch edit {
            case .rename(let path):
                let new = try FileOps.rename(path, to: name, root: root)
                self.follow(from: path, to: new)
            case .newFile(let folder):
                let new = try FileOps.createFile(named: name, in: folder, root: root)
                if !folder.isEmpty { self.expanded.insert(folder) }
                self.open(file: new, pinned: true)
            case .newFolder(let folder):
                let new = try FileOps.createFolder(named: name, in: folder, root: root)
                if !folder.isEmpty { self.expanded.insert(folder) }
                self.expanded.insert(new)
            }
        }
    }

    func duplicate(_ path: String) {
        guard let root = workspace?.root else { return }
        perform { _ = try FileOps.duplicate(path, root: root) }
    }

    func move(_ path: String, into folder: String) {
        guard let root = workspace?.root else { return }
        perform {
            let new = try FileOps.move(path, into: folder, root: root)
            if !folder.isEmpty { self.expanded.insert(folder) }
            self.follow(from: path, to: new)
        }
    }

    /// Files dragged in from Finder are copied, never moved out of where they came from.
    func copyIn(_ urls: [URL], into folder: String) {
        guard let root = workspace?.root else { return }
        perform {
            for url in urls { _ = try FileOps.copyIn(url, into: folder, root: root) }
            if !folder.isEmpty { self.expanded.insert(folder) }
        }
    }

    /// To the Trash. An open file with unsaved changes is refused rather than thrown away.
    func trash(_ path: String) {
        guard let root = workspace?.root else { return }
        let affected = openPaths.filter { FileOps.remap($0, from: path, to: path) != nil }
        if let dirty = affected.first(where: { documents[$0]?.isDirty == true }) {
            notice = "Save or close \((dirty as NSString).lastPathComponent) before moving it to the Trash."
            return
        }
        perform {
            try FileOps.trash(path, root: root)
            for open in affected {
                for index in self.panes.indices { self.panes[index].close(open) }
                self.documents[open] = nil
            }
            self.recentFiles.removeAll { FileOps.remap($0, from: path, to: path) != nil }
            self.collapseEmptyPanes()
            self.loadActive()
        }
    }

    /// Runs a file operation, then refreshes the tree and saves state; a failure becomes the toast.
    private func perform(_ operation: () throws -> Void) {
        do {
            agent.treeChanged(); try operation()
        } catch {
            notice = error.localizedDescription
        }
        persist()
        Task { await workspace?.refresh() }
    }

    private func follow(from old: String, to new: String) {
        guard let workspace else { return }
        for index in panes.indices {
            for path in panes[index].paths {
                if let moved = FileOps.remap(path, from: old, to: new) { panes[index].rename(path, to: moved) }
            }
        }
        for (path, document) in documents {
            guard let moved = FileOps.remap(path, from: old, to: new) else { continue }
            documents[path] = nil
            document.moved(to: workspace.url(for: moved))
            documents[moved] = document
            if document.state == .ready { languages.opened(path: moved, text: document.storage.string) }
        }
        expanded = Set(expanded.map { FileOps.remap($0, from: old, to: new) ?? $0 })
        recentFiles = recentFiles.map { FileOps.remap($0, from: old, to: new) ?? $0 }
    }
}
