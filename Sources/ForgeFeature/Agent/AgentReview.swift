import AinkradAppKit
import ForgeLanguage
import Foundation
import Observation

/// Changes made to open files from outside Forge (an agent, a formatter, git), kept for review against the
/// text Forge had just before — until each change is kept or undone. Typing in a file keeps its changes:
/// from then on they are yours.
@MainActor
@Observable
final class AgentReview {
    struct FileChanges: Equatable {
        /// What Forge had before the outside edits, with every change kept since folded in.
        var baseline: String
        var diff: AinkradFileDiff
        let since: Date
    }

    private(set) var files: [String: FileChanges] = [:]
    /// The change the review bar is on, per file (index into the diff's hunks).
    var current: [String: Int] = [:]
    /// The old lines shown under the chip.
    var showingWas = false
    /// Files whose next edit is our own undo (recompute, do not keep everything).
    @ObservationIgnored private var expecting: Set<String> = []

    /// A file this long is reloaded without review (the kit's diff is quadratic).
    static let lineLimit = 4_000

    func reset() {
        files = [:]
        current = [:]
        expecting = []
    }

    /// Forge reloaded a clean file someone else rewrote: `before` was its text. Edits in a row compare
    /// against the first one's baseline.
    func reloaded(_ path: String, before: String, after: String) {
        guard after.utf8.reduce(1, { $1 == 10 ? $0 + 1 : $0 }) <= Self.lineLimit else { return }
        let existing = files[path]
        set(path, baseline: existing?.baseline ?? before, text: after, since: existing?.since ?? Date())
    }

    /// The buffer changed in Forge: our own undo just landed (recompute), or the user typed (keep it all).
    func edited(_ path: String, text: String) {
        guard let file = files[path] else { return }
        if expecting.remove(path) != nil {
            set(path, baseline: file.baseline, text: text, since: file.since)
        } else {
            forget(path)
        }
    }

    func closed(_ path: String) { forget(path) }

    // MARK: - Keep / undo

    /// Keep: the change becomes part of what Forge has seen.
    func keep(_ path: String, hunk: Int, text: String) {
        guard let file = files[path], file.diff.hunks.indices.contains(hunk) else { return }
        let others = Set(file.diff.hunks.map(\.id)).subtracting([file.diff.hunks[hunk].id])
        set(path, baseline: ReplacePlan.reconstruct(file.diff, rejecting: others), text: text, since: file.since)
    }

    func keepAll(_ path: String) { forget(path) }

    /// Undo: the replacement that puts the change's old lines back (made through the editor, so undoable).
    func undo(_ path: String, hunk: Int) -> TextChange? {
        guard let file = files[path], let change = file.diff.hunks[safe: hunk] else { return nil }
        expecting.insert(path)
        return Self.reverting(change)
    }

    /// Undo All: the whole text back to the baseline.
    func undoAll(_ path: String, text: String) -> TextChange? {
        guard let file = files[path] else { return nil }
        expecting.insert(path)
        return TextChange(start: (0, 0), end: LineIndex(text).position(of: (text as NSString).length), newText: file.baseline)
    }

    // MARK: - Geometry

    /// 1-based lines the outside edits wrote (washed and barred), and those after which lines went (notched).
    func lines(_ path: String) -> (written: [Int], removedAfter: [Int]) {
        guard let file = files[path] else { return ([], []) }
        var written: [Int] = []
        var removed: [Int] = []
        for hunk in file.diff.hunks {
            let inserted = hunk.lines.compactMap { $0.kind == .insertion ? $0.newNumber : nil }
            written += inserted
            if inserted.isEmpty { removed.append(Self.lineBefore(hunk)) }
        }
        return (written, removed)
    }

    /// The line a change's chip sits on: its first written line, else the line before what went.
    func anchorLine(_ path: String, hunk: Int) -> Int? {
        guard let change = files[path]?.diff.hunks[safe: hunk] else { return nil }
        return change.lines.first { $0.kind == .insertion }?.newNumber ?? max(1, Self.lineBefore(change))
    }

    /// The change holding 1-based `line`, if any.
    func hunk(_ path: String, containing line: Int) -> Int? {
        files[path]?.diff.hunks.firstIndex { hunk in
            hunk.lines.contains { $0.kind == .insertion && $0.newNumber == line } || (Self.lineBefore(hunk) == line && !hunk.lines.contains { $0.kind == .insertion })
        }
    }

    // MARK: - Internals

    private func set(_ path: String, baseline: String, text: String, since: Date) {
        let diff = AinkradDiffEngine.compute(old: baseline, new: text, path: path, context: 1)
        if diff.hunks.isEmpty {
            forget(path)
        } else {
            files[path] = FileChanges(baseline: baseline, diff: diff, since: since)
            current[path] = min(current[path] ?? 0, diff.hunks.count - 1)
        }
    }

    private func forget(_ path: String) {
        files[path] = nil
        current[path] = nil
        expecting.remove(path)
    }

    /// The new line just before a change's first old-or-new line (0 at the top).
    private static func lineBefore(_ hunk: AinkradDiffHunk) -> Int {
        var last = 0
        for line in hunk.lines {
            if line.kind == .context, let number = line.newNumber { last = number } else { break }
        }
        return last
    }

    /// Replaces the change's new lines (with its context) by its old ones.
    static func reverting(_ hunk: AinkradDiffHunk) -> TextChange {
        let old = hunk.lines.filter { $0.kind != .insertion }.map(\.text)
        let firstNew = hunk.lines.first { $0.kind != .deletion }?.newNumber ?? (lineBefore(hunk) + 1)
        let newCount = hunk.lines.filter { $0.kind != .deletion }.count
        return TextChange(
            start: (firstNew - 1, 0), end: (firstNew - 1 + newCount, 0),
            newText: old.map { $0 + "\n" }.joined())
    }
}
