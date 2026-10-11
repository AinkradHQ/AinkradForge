import AinkradAppKit
import Foundation

/// What a line's blame says: who last changed it, when, and in which commit.
struct BlameLine: Equatable, Sendable {
    let hash: String
    let author: String
    let time: Date
    let summary: String

    /// A line not committed yet (edited in the buffer, or new): git blames it on the all-zero hash.
    var isUncommitted: Bool { hash.allSatisfy { $0 == "0" } }
}

/// A commit, as the blame card shows it.
struct CommitCard: Equatable, Sendable {
    let hash: String
    let author: String
    let when: String
    let subject: String
    let stat: String
}

/// Parsers and patch-building for the editor's git: pure, so each is tested without a repository.
enum GitLines {
    /// `git blame --porcelain -L n,n` → the line's blame.
    static func blame(_ porcelain: String) -> BlameLine? {
        var lines = porcelain.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let header = lines.first, let hash = header.split(separator: " ").first.map(String.init), hash.count >= 7 else {
            return nil
        }
        lines.removeFirst()
        func field(_ key: String) -> String? {
            lines.first { $0.hasPrefix(key + " ") }.map { String($0.dropFirst(key.count + 1)) }
        }
        let time = field("author-time").flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:)) ?? Date()
        return BlameLine(hash: hash, author: field("author") ?? "", time: time, summary: field("summary") ?? "")
    }

    /// The hunks of `text` against `head` (nil: the file is new — all of it added), with no context lines.
    /// ponytail: files over 4,000 lines get no marks (the kit's diff is quadratic); a Myers diff if that bites.
    static func hunks(head: String?, text: String, path: String) -> [AinkradDiffHunk] {
        guard text.utf8.reduce(1, { $1 == 10 ? $0 + 1 : $0 }) <= 4_000 else { return [] }
        // With no context the kit leaves an insertion's old start (and a deletion's new start) at 0; git's
        // zero-context form wants the line after which it happens — the other side's start less the drift
        // of the hunks before.
        var drift = 0
        return AinkradDiffEngine.compute(old: head ?? "", new: text, path: path, context: 0).hunks.map { hunk in
            defer { drift += hunk.newCount - hunk.oldCount }
            return AinkradDiffHunk(
                id: hunk.id, oldStart: hunk.oldCount == 0 ? hunk.newStart - 1 - drift : hunk.oldStart, oldCount: hunk.oldCount,
                newStart: hunk.newCount == 0 ? hunk.oldStart - 1 + drift : hunk.newStart, newCount: hunk.newCount,
                lines: hunk.lines)
        }
    }

    /// A zero-context patch that stages one hunk (`git apply --cached --unidiff-zero`). `path` is repo-relative.
    static func patch(path: String, hunk: AinkradDiffHunk) -> String {
        let old = hunk.lines.filter { $0.kind == .deletion }.map { "-" + $0.text }
        let new = hunk.lines.filter { $0.kind == .insertion }.map { "+" + $0.text }
        return ([
            "diff --git a/\(path) b/\(path)", "--- a/\(path)", "+++ b/\(path)",
            "@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@",
        ] + old + new).joined(separator: "\n") + "\n"
    }
}
