import AinkradAppKit
import Foundation

extension AgentReview {
    /// Review All's unticked changes of one file, by content: the baseline lines they remove and the lines they
    /// write, each placed by a line diff in the file's next diff (the FD55 line tracking). Hunk positions moved
    /// when a later outside write added a change above, and Done undid the wrong one (E1D5 FD63).
    struct Untick: Equatable, Sendable {
        var removed: SearchModel.TrackedLines
        var written: SearchModel.TrackedLines

        init(_ hunks: Set<Int>, of diff: AinkradFileDiff) {
            let chosen = diff.hunks.filter { hunks.contains($0.id) }
            removed = SearchModel.TrackedLines(
                lines: TextSearch.lineHashes(diff.original), indexes: Set(chosen.flatMap(\.changedLines)))
            written = SearchModel.TrackedLines(
                lines: TextSearch.lineHashes(Self.updated(diff)), indexes: Set(chosen.flatMap(\.writtenLines)))
        }

        /// The hunks of `diff` that remove or write a tracked line.
        func hunks(in diff: AinkradFileDiff) -> Set<Int> {
            let removed = removed.placed(in: TextSearch.lineHashes(diff.original)).indexes
            let written = written.placed(in: TextSearch.lineHashes(Self.updated(diff))).indexes
            return Set(
                diff.hunks.filter { hunk in
                    hunk.changedLines.contains(where: removed.contains) || hunk.writtenLines.contains(where: written.contains)
                }.map(\.id))
        }

        /// The text the diff leads to.
        private static func updated(_ diff: AinkradFileDiff) -> String { ReplacePlan.reconstruct(diff, rejecting: []) }
    }
}

extension AinkradDiffHunk {
    /// The new text's lines this hunk writes, 0-based (`changedLines`: the original's it removes).
    fileprivate var writtenLines: [Int] { lines.compactMap { $0.kind == .insertion ? $0.newNumber.map { $0 - 1 } : nil } }
}
