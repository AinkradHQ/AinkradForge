import AinkradAppKit
import ForgeEditor
import ForgeLanguage
import Foundation

/// Outside changes to files that are not open, and the Review All pane over every outside change.
extension ForgeModel {
    /// A document finished loading.
    func loaded(_ path: String) {
        gitChanged(path)
        if let document = documents[path] {
            agent.saw(path, text: document.storage.string)
            agent.settled(path)
        }
    }

    /// The watcher reported `paths`: closed files that changed from outside join the review. `known` is the
    /// tree before this change — a file not in it is new.
    func outsideChanges(_ paths: [String], known: Set<String>) async {
        guard let workspace else { return }
        let base = workspace.root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let git = Git(directory: workspace.root)
        for absolute in Set(paths) {
            let full = URL(fileURLWithPath: absolute).standardizedFileURL.resolvingSymlinksInPath().path
            guard full.hasPrefix(base), !full.contains("/.git/") else { continue }
            let path = String(full.dropFirst(base.count))
            guard documents[path] == nil, !agent.isOwn(path) else { continue }
            var isFolder: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: full, isDirectory: &isFolder)
            guard !isFolder.boolValue else { continue }
            let current = exists ? SearchModel.readText(URL(fileURLWithPath: full)) : nil
            guard !exists || current != nil else { continue }  // binary or too large: not reviewable
            var baseline = agent.lastSeen(path)
            if baseline == nil { baseline = try? await git.run(["show", ":./\(path)"]) }
            // No baseline: new if the tree did not have it (and shows it now — not an ignored file); else there is
            // nothing to compare with.
            if baseline == nil, current != nil, known.contains(path) || !workspace.files.contains(path) { continue }
            if baseline == nil, Self.inHiddenFolder(path) { continue }
            agent.outside(path, baseline: baseline, current: current)
        }
    }

    /// Under a dot-folder (`.build/`, `.swiftpm/`, `.next/`): an untracked file there is tool output — a language
    /// server's index, a build — not an agent's edit, even in a repo whose `.gitignore` forgot it (E0 FD7).
    nonisolated static func inHiddenFolder(_ path: String) -> Bool {
        path.split(separator: "/").dropLast().contains { $0.hasPrefix(".") }
    }

    /// A file in review. `diff` is nil while a closed file is still being diffed, or for good when it is too long
    /// to diff (`isTooLarge`) — then it is kept or undone whole (FD53).
    struct ReviewEntry {
        let path: String
        let diff: AinkradFileDiff?
        var isNew = false
        var isDeleted = false
        var isTooLarge = false
    }

    /// Every file in review with its diff (baseline → now), sorted by path. Cheap: closed files' diffs are cached
    /// (`AgentReview.otherDiffs`), never computed here (E1D4 FD52).
    var reviewEntries: [ReviewEntry] {
        var entries = agent.files.map { ReviewEntry(path: $0.key, diff: $0.value.diff) }
        for (path, other) in agent.others {
            let cached = agent.otherDiffs[path]
            entries.append(
                ReviewEntry(
                    path: path, diff: cached?.diff, isNew: other.baseline == nil, isDeleted: other.current == nil,
                    isTooLarge: cached != nil && cached?.diff == nil))
        }
        return entries.sorted { $0.path < $1.path }
    }

    /// Done: each file's unticked changes undone, the rest kept, the review cleared. Undo All undoes every
    /// change — a file too long to diff included, whole.
    func finishReview(undoAll: Bool = false) {
        guard let workspace else { return }
        for (path, file) in agent.files {
            let rejected = undoAll ? Set(file.diff.hunks.map(\.id)) : agent.unticked[path] ?? []
            // Open: through the editor, so it is undoable.
            if !rejected.isEmpty, let document = documents[path] {
                let text = ReplacePlan.reconstruct(file.diff, rejecting: rejected)
                if let change = agent.undoAll(path, text: document.storage.string) {
                    apply([path: [TextChange(start: change.start, end: change.end, newText: text)]])
                }
            }
            agent.keepAll(path)
            agent.settled(path)
        }
        for (path, other) in agent.others {
            defer { agent.settled(path) }
            if undoAll {
                undoWhole(path, other, in: workspace)
                continue
            }
            guard let (diff, rejected) = agent.untickedDiff(path), !rejected.isEmpty else { continue }
            if rejected.count == diff.hunks.count {
                undoWhole(path, other, in: workspace)
            } else {
                if other.current == nil { try? Data().write(to: workspace.url(for: path)) }
                _ = write(ReplacePlan.reconstruct(diff, rejecting: rejected), to: path, in: workspace)
            }
        }
        agent.reviewingAll = false
        agent.turns.clear()
        Task { await workspace.refresh() }
    }

    /// A closed file's Keep or Undo, whole — the way out for a file too long to diff (FD53).
    func settleOutside(_ path: String, undo: Bool) {
        guard let workspace, let other = agent.others[path] else { return }
        if undo { undoWhole(path, other, in: workspace) }
        agent.settled(path)
        if undo { Task { await workspace.refresh() } }
    }

    /// Puts a closed file back as it was: a new one goes to the Trash, a deleted one comes back.
    private func undoWhole(_ path: String, _ other: AgentReview.OtherFile, in workspace: Workspace) {
        guard let baseline = other.baseline else {
            try? FileManager.default.trashItem(at: workspace.url(for: path), resultingItemURL: nil)
            return
        }
        if other.current == nil { try? Data().write(to: workspace.url(for: path)) }
        _ = write(baseline, to: path, in: workspace)
    }

    func keepAllOutside() {
        for path in Array(agent.files.keys) { agent.keepAll(path) }
        for path in Array(agent.others.keys) { agent.settled(path) }
        agent.reviewingAll = false
        agent.turns.clear()
    }
}
