import Foundation
import Testing

@testable import ForgeFeature

/// ✕ on a result (FP57, mockup 07) and ⇄ on one match (FP63, mockup 08).
@MainActor
@Suite("Result actions")
struct ResultActionTests {
    private func workspace(_ files: [String: Data]) async throws -> (ForgeModel, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("forge-acts-\(UUID().uuidString.prefix(8))")
        for (path, data) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let model = ForgeModel(store: ForgeStore(documents: MemoryDocs()))
        await model.start(launch: root.path)
        return (model, root)
    }

    private func search(_ model: ForgeModel, _ query: String) async throws {
        model.search.query.text = query
        model.search.replacement = "isActive"
        model.rerunSearch()
        try await settle(model)
    }

    private func settle(_ model: ForgeModel) async throws {
        try await Task.sleep(for: .milliseconds(20))
        for _ in 0..<100 {
            if case .done = model.search.status { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func onlyTheChosenLinesAreReplaced() throws {
        let text = "a isSelected\nb\r\nc isSelected isSelected\nd isSelected"
        let regex = try #require(try SearchQuery(text: "isSelected").compile())
        let out = TextSearch.replace(in: text, regex: regex, with: "X", isRegex: false, preserveCase: false) { $0 == 3 }
        #expect(out.count == 2)
        #expect(out.text == "a isSelected\nb\r\nc X X\nd isSelected")
    }

    @Test func dismissingDropsALineOrAFileFromTheListAndFromReplaceAll() async throws {
        let (model, root) = try await workspace([
            "A.swift": Data("let isSelected = 1\nisSelected()\n".utf8), "B.swift": Data("var isSelected = 2\n".utf8),
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        try await search(model, "isSelected")
        #expect(model.search.lineCount == 3)

        model.search.dismiss("A.swift", line: 2)
        #expect(model.search.results.first { $0.path == "A.swift" }?.matches.map(\.line) == [1])
        if case .done(let lines, let files, _, _) = model.search.status { #expect(lines == 2 && files == 2) }
        model.search.dismiss("B.swift")
        #expect(model.search.results.map(\.path) == ["A.swift"])

        model.replaceAll()
        try await settle(model)
        #expect(try String(contentsOf: root.appending(path: "A.swift"), encoding: .utf8) == "let isActive = 1\nisSelected()\n")
        #expect(try String(contentsOf: root.appending(path: "B.swift"), encoding: .utf8) == "var isSelected = 2\n")
        // The re-run keeps the dismissed results out; a new query brings them back.
        #expect(model.search.results.isEmpty)
        try await search(model, "isSel")
        #expect(model.search.lineCount == 2)
    }

    @Test func replacingOneMatchWritesAClosedFileInItsEncodingAndAnOpenOneInItsBuffer() async throws {
        let closed = Data([0xEF, 0xBB, 0xBF]) + Data("let isSelected = 1\r\nisSelected()\r\n".utf8)
        let (model, root) = try await workspace(["Closed.swift": closed, "Open.swift": Data("isSelected\nvar isSelected = 2\n".utf8)])
        defer { try? FileManager.default.removeItem(at: root) }
        model.open(file: "Open.swift", pinned: true)
        for _ in 0..<50 where model.documents["Open.swift"]?.state != .ready { try await Task.sleep(for: .milliseconds(20)) }
        try await search(model, "isSelected")
        #expect(model.search.lineCount == 4)

        #expect(model.replace(in: "Closed.swift", line: 2) == 1)
        try await settle(model)
        #expect(try Data(contentsOf: root.appending(path: "Closed.swift")) == Data([0xEF, 0xBB, 0xBF]) + Data("let isSelected = 1\r\nisActive()\r\n".utf8))
        #expect(model.search.lineCount == 3)

        #expect(model.replace(in: "Open.swift", line: 2) == 1)
        try await settle(model)
        let open = try #require(model.documents["Open.swift"])
        #expect(open.storage.string == "isSelected\nvar isActive = 2\n" && open.isDirty)
        #expect(try String(contentsOf: root.appending(path: "Open.swift"), encoding: .utf8) == "isSelected\nvar isSelected = 2\n")
        #expect(model.search.lineCount == 2)
    }
}
