import AinkradAppKit
import Foundation

/// What a replace would do to one file: its text now, its text after, and the diff to preview.
struct ReplacePlan: Equatable {
    let path: String
    let original: String
    let updated: String
    let count: Int
    /// `nil` for a file too long to diff interactively (the kit's diff is quadratic); it can still be replaced.
    let diff: AinkradFileDiff?

    static let previewLineLimit = 4_000

    static func make(
        path: String, text: String, regex: NSRegularExpression, replacement: String, isRegex: Bool, preserveCase: Bool
    ) -> ReplacePlan {
        let result = TextSearch.replace(in: text, regex: regex, with: replacement, isRegex: isRegex, preserveCase: preserveCase)
        return make(path: path, original: text, updated: result.text, count: result.count)
    }

    static func make(path: String, original: String, updated: String, count: Int) -> ReplacePlan {
        let lines = original.utf8.reduce(1) { $1 == 10 ? $0 + 1 : $0 }
        let diff = lines <= previewLineLimit ? AinkradDiffEngine.compute(old: original, new: updated, path: path, context: 2) : nil
        return ReplacePlan(path: path, original: original, updated: updated, count: count, diff: diff)
    }

    /// The text to write: every hunk applied except the rejected ones, which keep their original lines.
    func text(rejecting rejected: Set<Int>) -> String {
        guard let diff, !rejected.isEmpty else { return updated }
        return Self.reconstruct(diff, rejecting: rejected)
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
