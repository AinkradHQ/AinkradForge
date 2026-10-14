import Foundation
import Testing

@testable import ForgeFeature

/// Closed files changed from outside: what joins the review, and what Done writes.
@MainActor
@Suite("Review all")
struct ReviewAllTests {
    private func workspace(_ files: [String: String]) async throws -> (ForgeModel, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("forge-review-\(UUID().uuidString.prefix(8))")
        for (path, text) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let model = ForgeModel(store: ForgeStore(documents: MemoryDocs()))
        await model.start(launch: root.path)
        return (model, root)
    }

    private let lines = (1...12).map { "line \($0)" }.joined(separator: "\n") + "\n"

    @Test func aSeenFileChangedWhileClosedIsReviewedAndDoneUndoesTheUnticked() async throws {
        let (model, root) = try await workspace(["A.txt": lines, "B.txt": "b\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        model.open(file: "A.txt", pinned: true)
        for _ in 0..<50 where model.documents["A.txt"]?.state != .ready { try await Task.sleep(for: .milliseconds(20)) }
        model.close("A.txt")

        let changed = lines.replacingOccurrences(of: "line 2\n", with: "line two\n").replacingOccurrences(of: "line 11\n", with: "line eleven\n")
        try changed.write(to: root.appending(path: "A.txt"), atomically: true, encoding: .utf8)
        // B was never seen and there is no git: nothing to compare it with, so it is not reviewed.
        try "b changed\n".write(to: root.appending(path: "B.txt"), atomically: true, encoding: .utf8)
        try "brand new\n".write(to: root.appending(path: "C.txt"), atomically: true, encoding: .utf8)
        await model.diskChanged(paths: ["A.txt", "B.txt", "C.txt"].map { root.appending(path: $0).path })

        #expect(Set(model.agent.others.keys) == ["A.txt", "C.txt"])
        await model.agent.diffsReady()
        let diff = try #require(model.reviewEntries.first { $0.path == "A.txt" }?.diff)
        #expect(diff.hunks.count == 2)
        #expect(model.reviewEntries.first { $0.path == "C.txt" }?.isNew == true)

        // Untick A's second change and C (new): Done undoes those and keeps A's first.
        model.agent.unticked["A.txt"] = [diff.hunks[1].id]
        model.agent.unticked["C.txt"] = Set(model.reviewEntries.first { $0.path == "C.txt" }?.diff?.hunks.map(\.id) ?? [])
        model.finishReview()
        let written = try String(contentsOf: root.appending(path: "A.txt"), encoding: .utf8)
        #expect(written.contains("line two") && written.contains("line 11\n"))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "C.txt").path))
        #expect(model.agent.count == 0)
    }

    /// sourcekit-lsp writes its index under `.build/`; in a repo whose `.gitignore` forgot it, those files are
    /// untracked and listed — they must not land in the review as agent edits (E0 FD7).
    @Test func untrackedFilesInDotFoldersAreNotOutsideChanges() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("forge-review-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try lines.write(to: root.appending(path: "A.txt"), atomically: true, encoding: .utf8)
        for args in [["init", "-q"], ["add", "-A"], ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init"]] {
            let git = Process()
            git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            git.arguments = args
            git.currentDirectoryURL = root
            try git.run()
            git.waitUntilExit()
        }
        let model = ForgeModel(store: ForgeStore(documents: MemoryDocs()))
        await model.start(launch: root.path)

        let index = root.appending(path: ".build/index/store/v5/units/main.o")
        try FileManager.default.createDirectory(at: index.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "unit\n".write(to: index, atomically: true, encoding: .utf8)
        try "brand new\n".write(to: root.appending(path: "D.txt"), atomically: true, encoding: .utf8)
        await model.diskChanged(paths: [index.path, root.appending(path: "D.txt").path])

        #expect(Set(model.agent.others.keys) == ["D.txt"])
        #expect(ForgeModel.inHiddenFolder(".build/x.o") && !ForgeModel.inHiddenFolder(".gitignore"))
    }

    /// A closed file past the diff's line limit is listed — too large to diff — and kept or undone whole: Undo All
    /// puts it back and the chip clears (E1D4 FD53).
    @Test func aFileTooLargeToDiffIsListedAndSettledWhole() async throws {
        let big = (1...5_000).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let (model, root) = try await workspace(["Big.txt": big, "Small.txt": "let a = 1\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        model.agent.saw("Big.txt", text: big)
        model.agent.saw("Small.txt", text: "let a = 1\n")
        try big.replacingOccurrences(of: "line 7\n", with: "line seven\n").write(to: root.appending(path: "Big.txt"), atomically: true, encoding: .utf8)
        try "let a = 2\n".write(to: root.appending(path: "Small.txt"), atomically: true, encoding: .utf8)
        await model.diskChanged(paths: ["Big.txt", "Small.txt"].map { root.appending(path: $0).path })
        await model.agent.diffsReady()

        #expect(model.agent.count == 2)
        #expect(model.reviewEntries.map(\.path) == ["Big.txt", "Small.txt"])
        #expect(model.reviewEntries.first?.isTooLarge == true && model.reviewEntries.first?.diff == nil)
        model.finishReview(undoAll: true)
        #expect(try String(contentsOf: root.appending(path: "Big.txt"), encoding: .utf8) == big)
        #expect(try String(contentsOf: root.appending(path: "Small.txt"), encoding: .utf8) == "let a = 1\n")
        #expect(model.agent.count == 0)

        // Done keeps one; the row's own Undo puts it back.
        let other = root.appending(path: "Other.txt")
        try big.write(to: other, atomically: true, encoding: .utf8)
        model.agent.saw("Other.txt", text: big)
        try "changed\n\(big)".write(to: other, atomically: true, encoding: .utf8)
        await model.diskChanged(paths: [other.path])
        #expect(model.agent.count == 1)
        model.finishReview()
        #expect(model.agent.count == 0)
        #expect(try String(contentsOf: other, encoding: .utf8).hasPrefix("changed\n"))
        try "changed again\n\(big)".write(to: other, atomically: true, encoding: .utf8)
        await model.diskChanged(paths: [other.path])
        #expect(model.agent.count == 1)
        model.settleOutside("Other.txt", undo: true)
        #expect(try String(contentsOf: other, encoding: .utf8) == big)
        #expect(model.agent.count == 0)
    }

    @Test func forgesOwnWritesAreNotOutsideChanges() async throws {
        let (model, root) = try await workspace(["A.txt": lines])
        defer { try? FileManager.default.removeItem(at: root) }
        guard let workspace = model.workspace else { return }
        #expect(model.write("rewritten\n", to: "A.txt", in: workspace))
        await model.diskChanged(paths: [root.appending(path: "A.txt").path])
        #expect(model.agent.count == 0)
    }
}
