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

    /// Every file in review with its diff (baseline → now), sorted by path.
    var reviewEntries: [(path: String, diff: AinkradFileDiff, isNew: Bool, isDeleted: Bool)] {
        var entries: [(String, AinkradFileDiff, Bool, Bool)] = []
        for (path, file) in agent.files { entries.append((path, file.diff, false, false)) }
        for (path, other) in agent.others {
            let old = other.baseline ?? ""
            let new = other.current ?? ""
            let lines = { (text: String) in text.utf8.reduce(1) { $1 == 10 ? $0 + 1 : $0 } }
            guard lines(old) <= AgentReview.lineLimit, lines(new) <= AgentReview.lineLimit else { continue }
            entries.append((path, AinkradDiffEngine.compute(old: old, new: new, path: path, context: 2), other.baseline == nil, other.current == nil))
        }
        return entries.sorted { $0.0 < $1.0 }
    }

    /// Done: each file's unticked changes undone, the rest kept, the review cleared.
    func finishReview(undoAll: Bool = false) {
        guard let workspace else { return }
        for entry in reviewEntries {
            let rejected = undoAll ? Set(entry.diff.hunks.map(\.id)) : agent.unticked[entry.path] ?? []
            defer { agent.settled(entry.path) }
            guard !rejected.isEmpty else {
                agent.keepAll(entry.path)
                continue
            }
            if let document = documents[entry.path], agent.files[entry.path] != nil {
                // Open: through the editor, so it is undoable.
                let text = ReplacePlan.reconstruct(entry.diff, rejecting: rejected)
                if let change = agent.undoAll(entry.path, text: document.storage.string) {
                    apply([entry.path: [TextChange(start: change.start, end: change.end, newText: text)]])
                }
                agent.keepAll(entry.path)
            } else if entry.isNew, rejected.count == entry.diff.hunks.count {
                try? FileManager.default.trashItem(at: workspace.url(for: entry.path), resultingItemURL: nil)
            } else {
                let text = entry.isDeleted && rejected.count == entry.diff.hunks.count
                    ? entry.diff.original : ReplacePlan.reconstruct(entry.diff, rejecting: rejected)
                if entry.isDeleted { try? Data().write(to: workspace.url(for: entry.path)) }
                _ = write(text, to: entry.path, in: workspace)
            }
        }
        agent.reviewingAll = false
        agent.turns.clear()
        Task { await workspace.refresh() }
    }

    func keepAllOutside() {
        for path in Array(agent.files.keys) { agent.keepAll(path) }
        for path in Array(agent.others.keys) { agent.settled(path) }
        agent.reviewingAll = false
        agent.turns.clear()
    }
}
