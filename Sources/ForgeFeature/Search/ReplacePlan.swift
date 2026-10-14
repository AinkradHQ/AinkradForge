import AinkradAppKit
import Foundation

/// What a replace would do to one file: its text now, its text after, and — once `diffed()` — the diff to preview.
struct ReplacePlan: Equatable, Sendable {
    let path: String
    let original: String
    let updated: String
    let count: Int
    /// The preview's diff; `nil` until `diffed()`, and for good for a file too long to diff interactively (the
    /// kit's diff is quadratic). Replacing never needs it: unticked lines are left out of the replace itself.
    private(set) var diff: AinkradFileDiff?

    static let previewLineLimit = 4_000

    /// The plan without its diff: what Replace writes (E1D5 FD62 — Replace All diffed every file on the main thread).
    static func make(
        path: String, text: String, regex: NSRegularExpression, replacement: String, isRegex: Bool, preserveCase: Bool,
        limit: Int? = nil, lines: ((Int) -> Bool)? = nil
    ) -> ReplacePlan {
        let result = TextSearch.replace(
            in: text, regex: regex, with: replacement, isRegex: isRegex, preserveCase: preserveCase, limit: limit, lines: lines)
        return ReplacePlan(path: path, original: text, updated: result.text, count: result.count)
    }

    static func make(path: String, original: String, updated: String, count: Int) -> ReplacePlan {
        ReplacePlan(path: path, original: original, updated: updated, count: count).diffed()
    }

    /// This plan with its diff — real work on a long file: the preview runs it off the main thread.
    nonisolated func diffed() -> ReplacePlan {
        var plan = self
        let lines = original.utf8.reduce(1) { $1 == 10 ? $0 + 1 : $0 }
        if lines <= Self.previewLineLimit {
            plan.diff = AinkradDiffEngine.compute(old: original, new: updated, path: path, context: 2)
        }
        return plan
    }

    /// The text to write: every hunk applied except the rejected ones, which keep their original lines.
    func text(rejecting rejected: Set<Int>) -> String {
        guard let diff, !rejected.isEmpty else { return updated }
        return Self.reconstruct(diff, rejecting: rejected)
    }

    /// The hunks `unticked` covers in this plan's diff — those changing a line it tracks, placed in this plan's
    /// text — however the file changed since the untick (E1D4 FD55). For the preview's ticks; Replace leaves the
    /// unticked lines out of the replace instead (`ForgeModel.replacePlan(for:keepingUnticked:)`).
    func rejected(_ unticked: SearchModel.TrackedLines?) -> Set<Int> {
        guard let diff, let unticked else { return [] }
        let lines = unticked.placed(in: TextSearch.lineHashes(original)).indexes
        return Set(diff.hunks.filter { $0.changedLines.contains { lines.contains($0) } }.map(\.id))
    }

    /// Unticked `hunks` of this plan's diff, as the original lines they change.
    func unticked(_ hunks: Set<Int>) -> SearchModel.TrackedLines? {
        guard let diff, !hunks.isEmpty else { return nil }
        let lines = diff.hunks.filter { hunks.contains($0.id) }.flatMap(\.changedLines)
        return SearchModel.TrackedLines(lines: TextSearch.lineHashes(original), indexes: Set(lines))
    }

    /// The original with accepted hunks' new lines and rejected hunks' old lines; outside hunks, verbatim.
    /// (The host has the same rule in `PartialEdit` — a kit home for it is the proposal.)
    static func reconstruct(_ diff: AinkradFileDiff, rejecting rejected: Set<Int>) -> String {
        let original = diff.original.isEmpty ? [] : diff.original.components(separatedBy: "\n")
        var out: [String] = []
        var cursor = 0
        for hunk in diff.hunks.sorted(by: { $0.oldStart < $1.oldStart }) {
            let start = max(0, hunk.oldStart - 1)
            if start > cursor { out.append(contentsOf: original[cursor..<start]) }
            out.append(contentsOf: rejected.contains(hunk.id) ? hunk.oldLines : hunk.newLines)
            cursor = start + hunk.oldCount
        }
        if cursor < original.count { out.append(contentsOf: original[cursor...]) }
        return out.joined(separator: "\n")
    }
}

extension AinkradDiffHunk {
    /// The original's lines this hunk changes, 0-based.
    var changedLines: [Int] { lines.compactMap { $0.kind == .deletion ? $0.oldNumber.map { $0 - 1 } : nil } }
}
