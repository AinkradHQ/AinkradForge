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
        let entry = try #require(model.reviewEntries.first { $0.path == "A.txt" })
        #expect(entry.diff.hunks.count == 2)
        #expect(model.reviewEntries.first { $0.path == "C.txt" }?.isNew == true)

        // Untick A's second change and C (new): Done undoes those and keeps A's first.
        model.agent.unticked["A.txt"] = [entry.diff.hunks[1].id]
        model.agent.unticked["C.txt"] = Set(model.reviewEntries.first { $0.path == "C.txt" }?.diff.hunks.map(\.id) ?? [])
        model.finishReview()
        let written = try String(contentsOf: root.appending(path: "A.txt"), encoding: .utf8)
        #expect(written.contains("line two") && written.contains("line 11\n"))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "C.txt").path))
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
