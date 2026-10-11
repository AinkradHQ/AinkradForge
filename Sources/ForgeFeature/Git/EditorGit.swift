import AinkradAppKit
import AppKit
import ForgeEditor
import ForgeLanguage
import Foundation
import Observation

/// The peek at one change's old lines, pinned to its gutter mark.
struct GitPeek: Equatable {
    let pane: Int
    let path: String
    let hunk: Int
    let rect: CGRect
}

/// Blame on the caret's line, and the commit card when the pointer is on it.
struct BlameNote: Equatable {
    let path: String
    let line: Int
    let blame: BlameLine
    var card: CommitCard?
}

/// The editor's git: each open file's changes against HEAD, the peek, and blame on demand.
@MainActor
@Observable
final class EditorGit {
    /// Workspace-relative path → its hunks against HEAD.
    private(set) var hunks: [String: [AinkradDiffHunk]] = [:]
    var peek: GitPeek?
    var blameOn = false
    var blame: BlameNote?
    /// HEAD's text of each file asked for (nil: not in HEAD — a new file), until HEAD moves.
    @ObservationIgnored private var heads: [String: String?] = [:]
    @ObservationIgnored private var pending: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var blameTask: Task<Void, Never>?

    /// Forgets everything (a new workspace).
    func reset() {
        hunks = [:]
        heads = [:]
        peek = nil
        blame = nil
        pending.values.forEach { $0.cancel() }
        pending = [:]
    }

    /// HEAD (or the index) may have moved: re-read HEAD's text for the open files.
    func headMoved(open: [String: String], git: Git) {
        heads = [:]
        for (path, text) in open { update(path, text: text, git: git, delay: .zero) }
    }

    func closed(_ path: String) {
        pending.removeValue(forKey: path)?.cancel()
        hunks[path] = nil
        heads[path] = nil
        if peek?.path == path { peek = nil }
    }

    /// Recomputes `path`'s marks against HEAD after a short pause (typing restarts it).
    func update(_ path: String, text: @autoclosure () -> String, git: Git, delay: Duration = .milliseconds(300)) {
        let text = text()
        pending[path]?.cancel()
        pending[path] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            let head: String?
            if let cached = self.heads[path] {
                head = cached
            } else {
                // Not tracked (or no repository): no HEAD text, and no marks — a new file is not "all changed".
                guard (try? await git.run(["ls-files", "--error-unmatch", "--", path])) != nil else {
                    self.heads[path] = .some(nil)
                    self.hunks[path] = nil
                    return
                }
                head = try? await git.run(["show", "HEAD:./\(path)"])
                self.heads[path] = head
            }
            let found = await Task.detached(priority: .utility) { GitLines.hunks(head: head, text: text, path: path) }.value
            guard !Task.isCancelled else { return }
            self.hunks[path] = found.isEmpty ? nil : found
        }
    }

    /// The gutter marks for `path`: added / changed bars, removal notches.
    func marks(_ path: String, status: AinkradStatusColors) -> [EditorLineMark] {
        (hunks[path] ?? []).enumerated().map { index, hunk in
            if hunk.newCount == 0 {
                return EditorLineMark(lines: hunk.newStart...hunk.newStart, color: NSColor(status.danger), isRemoval: true, tag: index)
            }
            return EditorLineMark(
                lines: hunk.newStart...(hunk.newStart + hunk.newCount - 1),
                color: NSColor(hunk.oldCount == 0 ? status.success : status.warning), isRemoval: false, tag: index)
        }
    }

    /// The caret moved: blame its line (from the buffer, so unsaved edits do not shift it), after a pause.
    func caretMoved(path: String, line: Int, text: String, git: Git) {
        blameTask?.cancel()
        guard blameOn else { return }
        if blame?.path != path || blame?.line != line { blame = nil }
        blameTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let porcelain = try? await git.run(
                ["blame", "--porcelain", "-L", "\(line),\(line)", "--contents", "-", "--", path], input: Data(text.utf8))
            guard !Task.isCancelled, let porcelain, let found = GitLines.blame(porcelain) else { return }
            self?.blame = BlameNote(path: path, line: line, blame: found)
        }
    }

    /// The pointer is on the blame note: its commit's card.
    func loadCard(git: Git) {
        guard let note = blame, note.card == nil, !note.blame.isUncommitted else { return }
        Task {
            let summary = (try? await git.run(["show", "-s", "--format=%an%x00%ar%x00%s%x00%h", note.blame.hash])) ?? ""
            let stat = (try? await git.run(["show", "--shortstat", "--format=", note.blame.hash])) ?? ""
            let parts = summary.trimmingCharacters(in: .newlines).components(separatedBy: "\0")
            guard parts.count == 4, blame?.blame.hash == note.blame.hash else { return }
            blame?.card = CommitCard(
                hash: parts[3], author: parts[0], when: parts[1], subject: parts[2],
                stat: stat.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
