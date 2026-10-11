import Foundation
import Testing

@testable import ForgeFeature

@Suite("Git lines")
struct GitLinesTests {
    @Test func blamePorcelainParses() throws {
        let porcelain = """
            a41c9e2f00000000000000000000000000000000 21 21 1
            author Ahmed Elhalaby
            author-mail <a@b.c>
            author-time 1760000000
            summary feat(sidebar): selection as a glass capsule
            filename Sources/SidebarRow.swift
            \t.contentShape(Rectangle())
            """
        let blame = try #require(GitLines.blame(porcelain))
        #expect(blame.author == "Ahmed Elhalaby")
        #expect(blame.summary == "feat(sidebar): selection as a glass capsule")
        #expect(blame.time == Date(timeIntervalSince1970: 1_760_000_000))
        #expect(!blame.isUncommitted)
        #expect(GitLines.blame("0000000000000000000000000000000000000000 3 3 1\nauthor Not Committed Yet\n")?.isUncommitted == true)
    }

    /// Each kind of hunk, staged with git itself: the index ends up exactly as the buffer.
    @Test func zeroContextPatchesStageInGit() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("forge-git-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let git = Git(directory: root)
        let head = (1...12).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try head.write(to: root.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        for args in [["init", "-q"], ["add", "a.txt"], ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init"]] {
            _ = try await git.run(args)
        }
        // Added after line 2, line 6 changed, lines 9–10 deleted.
        var lines = head.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.insert("new A", at: 2)
        lines[6] = "line 6 changed"
        lines.removeSubrange(9...10)
        let text = lines.joined(separator: "\n")
        let hunks = GitLines.hunks(head: head, text: text, path: "a.txt")
        #expect(hunks.count == 3)
        for hunk in hunks.reversed() {
            _ = try await git.run(["apply", "--cached", "--unidiff-zero", "-"], input: Data(GitLines.patch(path: "a.txt", hunk: hunk).utf8))
        }
        #expect(try await git.run(["show", ":a.txt"]) == text)
    }
}
