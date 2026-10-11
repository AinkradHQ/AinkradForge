import AppKit
import ForgeEditor
import ForgeLanguage
import Foundation

/// The rename field on a symbol: what it was, what it becomes, and how far the change reaches.
struct RenameState: Equatable {
    let pane: Int
    let path: String
    let rect: CGRect
    let line: Int
    let character: Int
    let original: String
    var newName: String
    /// Places and files renaming touches (counted when the field opens).
    var places: Int?
    var files: Int?
}

/// Changes across files waiting in the preview, each file's hunks untickable as in Replace.
struct PendingEdit {
    let title: String
    let changes: [String: [TextChange]]
    let plans: [ReplacePlan]
    var rejected: [String: Set<Int>] = [:]
}

/// Rename, code actions and formatting: the server says what to change; Forge makes the change.
extension ForgeModel {
    /// Makes `changes` (workspace-relative path → changes). A file showing in an editor changes through it —
    /// undoable, the caret kept; another open file in its buffer; a closed file on disk. False if a write failed.
    @discardableResult
    func apply(_ changes: [String: [TextChange]]) -> Bool {
        guard let workspace else { return false }
        var written = true
        for (path, list) in changes where !list.isEmpty {
            if let document = documents[path], document.state == .ready, panes.contains(where: { $0.active == path }) {
                let index = LineIndex(document.storage.string)
                editSequence += 1
                editorEdits[path] = EditorEdits(
                    id: editSequence, changes: list.map { (index.range(from: $0.start, to: $0.end), $0.newText) })
            } else if let text = text(of: path) {
                written = write(TextChange.apply(list, to: text), to: path, in: workspace) && written
            }
        }
        return written
    }

    /// F2: the rename field on the symbol at the caret.
    func beginRename() {
        guard let path = tabs.active, let document = documents[path] else { return }
        let line = document.cursor.line - 1
        let character = document.cursor.column - 1
        let symbol = TextSearch.word(in: TextSearch.line(line, of: document.storage.string), at: character)
        guard !symbol.isEmpty else { return notice = "Put the caret on a symbol to rename it." }
        rename = RenameState(
            pane: activePane, path: path, rect: document.caretRect, line: line, character: character, original: symbol,
            newName: symbol)
        // A rename to a throwaway name, never applied, finds every place: the count for the hint. (Renaming to
        // the same name would not do — servers answer it with no changes.)
        Task {
            let places = await languages.rename(path: path, line: line, character: character, to: symbol + "_")
            guard rename?.path == path, rename?.original == symbol else { return }
            rename?.places = places.values.reduce(0) { $0 + $1.count }
            rename?.files = places.count
        }
    }

    /// ↵ previews the rename (as Replace does); ⇧↵ makes it at once.
    func commitRename(preview: Bool) {
        guard let state = rename else { return }
        rename = nil
        guard !state.newName.isEmpty, state.newName != state.original else { return }
        Task {
            let changes = await languages.rename(path: state.path, line: state.line, character: state.character, to: state.newName)
            guard !changes.isEmpty else { return notice = "The language server could not rename ‘\(state.original)’." }
            if preview {
                pendingEdit = PendingEdit(
                    title: "Rename ‘\(state.original)’ to ‘\(state.newName)’", changes: changes, plans: plans(for: changes))
            } else {
                apply(changes)
                notice = Self.summary(changes, verb: "Renamed")
            }
        }
    }

    /// The preview's Apply: every file, its unticked hunks left as they were.
    func applyPendingEdit() {
        guard let pending = pendingEdit else { return }
        pendingEdit = nil
        var changes = pending.changes
        for plan in pending.plans {
            guard let rejected = pending.rejected[plan.path], !rejected.isEmpty else { continue }
            // Part of a file: its whole text, as the preview shows it, replaces the whole text.
            let end = LineIndex(plan.original).position(of: (plan.original as NSString).length)
            changes[plan.path] = [TextChange(start: (0, 0), end: end, newText: plan.text(rejecting: rejected))]
        }
        apply(changes)
        notice = Self.summary(pending.changes, verb: "Changed")
    }

    /// ⌘.: the fixes and refactors for the caret's line, then Format Document, in a menu at the caret.
    func showCodeActions() {
        guard let path = tabs.active, let document = documents[path] else { return }
        let line = document.cursor.line - 1
        Task {
            // The whole line, not the caret: servers match fixes to diagnostics by overlap, and an empty range
            // overlaps nothing.
            let items = await languages.codeActions(path: path, from: (line, 0), to: (line + 1, 0))
            menuActions = items
            editSequence += 1
            actionMenu = EditorMenu(
                id: editSequence, titles: items.map(\.title) + ["Format Document"], dividerBefore: items.isEmpty ? nil : items.count)
        }
    }

    func pickCodeAction(_ index: Int?) {
        actionMenu = nil
        guard let index, let path = tabs.active else { return }
        guard menuActions.indices.contains(index) else { return formatDocument() }
        let item = menuActions[index]
        Task { apply(await languages.perform(item, path: path)) }
    }

    /// ⌥⇧F: the server's formatting of the active file, with the editor's tab settings.
    func formatDocument() {
        guard let path = tabs.active else { return }
        let settings = editorSettings
        Task {
            let changes = await languages.format(path: path, tabSize: settings.tabWidth, insertSpaces: settings.insertSpaces)
            if changes.isEmpty {
                notice = "Already formatted, or the language server cannot format this file."
            } else {
                apply([path: changes])
            }
        }
    }

    private func plans(for changes: [String: [TextChange]]) -> [ReplacePlan] {
        changes.sorted { $0.key < $1.key }.map { path, list in
            let original = text(of: path) ?? ""
            return ReplacePlan.make(path: path, original: original, updated: TextChange.apply(list, to: original), count: list.count)
        }
    }

    private static func summary(_ changes: [String: [TextChange]], verb: String) -> String {
        let places = changes.values.reduce(0) { $0 + $1.count }
        return "\(verb) \(places) place\(places == 1 ? "" : "s") in \(changes.count) file\(changes.count == 1 ? "" : "s"). Open files are unsaved — ⌘S or Save All writes them."
    }
}
