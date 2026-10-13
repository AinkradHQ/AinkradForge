import AinkradAppKit
import ForgeEditor
import ForgeLanguage
import Foundation

/// Changes made outside Forge — an agent, git, another editor.
extension ForgeModel {
    /// Refreshes the tree and git marks, and lets every open buffer compare itself with its file: a clean one
    /// reloads, a dirty one raises its conflict banner.
    func diskChanged(paths: [String] = []) async {
        let known = Set(workspace?.files ?? [])
        await workspace?.refresh()
        // A commit, checkout or stage moves what the gutter compares against.
        if let workspace {
            await tasks.refresh(root: workspace.root, files: workspace.files)
            git.headMoved(
                open: documents.compactMapValues { $0.state == .ready ? $0.storage.string : nil }, git: Git(directory: workspace.root))
        }
        for (path, document) in documents {
            let revision = document.revision
            let before = document.storage.string
            await document.checkDisk()
            // Reloaded from disk: the server gets the new text, and the change waits for review.
            if document.revision != revision {
                languages.changed(path: path) { document.storage.string }
                agent.reloaded(path, before: before, after: document.storage.string)
            }
        }
        await outsideChanges(paths, known: known)
    }
}

/// Editor settings, stored with the rest of Forge's state.
extension ForgeModel {
    var editorSettings: EditorSettings {
        get { store.document.editor ?? EditorSettings() }
        set { store.update { $0.editor = newValue } }
    }

    var editorOptions: EditorOptions {
        let s = editorSettings
        return EditorOptions(
            fontSize: s.fontSize, tabWidth: s.tabWidth, insertSpaces: s.insertSpaces, wrapLines: s.wrapLines,
            showMinimap: s.showMinimap, showInvisibles: s.showInvisibles)
    }
}

/// Search across files.
extension ForgeModel {
    /// Text of open files with unsaved edits — searched instead of their stale files on disk.
    var unsavedBuffers: [String: String] {
        Dictionary(uniqueKeysWithValues: unsavedPaths.compactMap { path in documents[path].map { (path, $0.storage.string) } })
    }

    /// ⌘⇧F: the Search tab, cursor in the query.
    func showSearch() {
        sideTab = .search
        searchFocusRequest += 1
    }
}

/// Replace across files. Open files change in their buffer (unsaved, ⌘S writes them); others are written in
/// their own encoding and line endings. Nothing with unsaved edits is ever overwritten on disk.
extension ForgeModel {
    /// What replacing in `path` would do, from its open buffer or its file — only the matches still listed
    /// (none dismissed with ✕), or with `line`, only the first match of that listed row. Matches are found by
    /// identity in the text as it is now (FD44), so lines that moved since the search can't swap places.
    func replacePlan(for path: String, line: Int? = nil) -> ReplacePlan? {
        guard let workspace, let regex = try? search.query.compile() else { return nil }
        let text: String? = documents[path].flatMap { $0.state == .ready ? $0.storage.string : nil }
            ?? SearchModel.readText(workspace.url(for: path))
        guard let text else { return nil }
        let dismissed = search.dismissedMatches[path] ?? []
        // ⇄'s row, as it was listed; a row no longer listed has nothing to replace.
        var target: LineMatch.Key?
        if let line {
            guard let listed = search.results.first(where: { $0.path == path })?.matches.first(where: { $0.line == line }) else {
                return ReplacePlan.make(path: path, original: text, updated: text, count: 0)
            }
            target = listed.key
        }
        let current = search.dismissedFiles.contains(path) ? [] : TextSearch.matches(in: text, regex: regex)
        let chosen = Set(current.filter { !dismissed.contains($0.key) && (target == nil || $0.key == target) }.map(\.line))
        return ReplacePlan.make(
            path: path, text: text, regex: regex, replacement: search.replacement, isRegex: search.query.regex,
            preserveCase: search.preserveCase, limit: line == nil ? nil : 1, lines: chosen.contains)
    }

    /// ⇄ on a result line: replaces that one match, the line's first (an unsaved edit in an open buffer; otherwise written in
    /// the file's own encoding), then searches again so the counts follow.
    @discardableResult
    func replace(in path: String, line: Int) -> Int {
        guard let plan = replacePlan(for: path, line: line), let workspace else { return 0 }
        guard plan.count > 0 else {
            // Never silently (FD45): the line no longer holds the match — the file changed since the search.
            notice = "Nothing to replace on line \(line) of \((path as NSString).lastPathComponent) — it changed since the search."
            rerunSearch()
            return 0
        }
        guard write(plan.updated, to: path, in: workspace) else { return 0 }
        // The preview's hunks are renumbered by the change: an untick would land on another hunk.
        search.rejected[path] = nil
        rerunSearch()
        return plan.count
    }

    /// Replaces in one file, leaving the preview's unticked hunks alone.
    @discardableResult
    func replace(in path: String, rerun: Bool = true) -> Int {
        guard let plan = replacePlan(for: path), plan.count > 0, let workspace else { return 0 }
        guard write(plan.text(rejecting: search.rejected[path] ?? []), to: path, in: workspace) else { return 0 }
        search.rejected[path] = nil
        if search.previewPath == path { search.previewPath = nil }
        if rerun { rerunSearch() }
        return plan.count
    }

    /// Puts `text` in `path`: its open buffer (unsaved), else the file in its own encoding and line endings.
    func write(_ text: String, to path: String, in workspace: Workspace) -> Bool {
        agent.wrote(path, text: text)
        if let document = documents[path], document.state == .ready {
            document.replaceText(text)
            languages.changed(path: path) { document.storage.string }
            return true
        }
        let url = workspace.url(for: path)
        do {
            guard let data = try? Data(contentsOf: url), case .text(_, let format) = TextFile.decode(data) else {
                throw FileOps.Failure(message: "\(path) could not be read.")
            }
            try TextFile.encode(text, as: format).write(to: url, options: .atomic)
            return true
        } catch {
            notice = error.localizedDescription
            return false
        }
    }

    /// Replace All, after the window's confirmation.
    func replaceAll() {
        search.confirmingReplaceAll = false
        let total = search.results.map(\.path).reduce(0) { $0 + replace(in: $1, rerun: false) }
        search.previewPath = nil
        notice = total == 0 ? nil : "Replaced \(total) match\(total == 1 ? "" : "es"). Open files are unsaved — ⌘S or Save All writes them."
        rerunSearch()
    }

    func rerunSearch() {
        guard let workspace else { return }
        search.schedule(root: workspace.root, files: workspace.files, buffers: unsavedBuffers, delay: .zero)
    }
}

