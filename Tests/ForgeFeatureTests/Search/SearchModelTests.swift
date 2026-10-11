import Foundation
import Testing

@testable import ForgeFeature

@MainActor
@Suite("Search model")
struct SearchModelTests {
    private func folder(_ files: [String: String]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("forge-search-\(UUID().uuidString.prefix(8))")
        for (path, text) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    private func settle(_ search: SearchModel) async throws {
        for _ in 0..<100 {
            if case .done = search.status { return }
            if case .failed = search.status { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func findsMatchesFiltersByGlobAndPrefersUnsavedBuffers() async throws {
        let files = ["Sources/A.swift": "let isSelected = true\n", "Sources/B.swift": "no match\n", "Docs/C.md": "isSelected here\n"]
        let root = try folder(files)
        defer { try? FileManager.default.removeItem(at: root) }
        let search = SearchModel()
        search.query.text = "isSelected"
        search.schedule(root: root, files: Array(files.keys), buffers: [:], delay: .zero)
        try await settle(search)
        #expect(Set(search.results.map(\.path)) == ["Sources/A.swift", "Docs/C.md"])
        #expect(search.status == .done(lines: 2, files: 2, milliseconds: { if case .done(_, _, let ms, _) = search.status { ms } else { 0 } }(), capped: false))

        search.include = "Sources/**"
        search.schedule(root: root, files: Array(files.keys), buffers: ["Sources/B.swift": "isSelected now\n"], delay: .zero)
        try await settle(search)
        #expect(search.results.map(\.path).sorted() == ["Sources/A.swift", "Sources/B.swift"])
    }

    @Test func anInvalidRegexSaysSo() async throws {
        let search = SearchModel()
        search.query = SearchQuery(text: "(", regex: true)
        search.schedule(root: URL(fileURLWithPath: "/"), files: [], buffers: [:], delay: .zero)
        #expect(search.status == .failed("Not a valid regular expression."))
    }

    @Test func aBroadSearchStopsAtTheCap() async throws {
        let big = String(repeating: "x\n", count: SearchModel.cap + 500)
        let root = try folder(["big.txt": big])
        defer { try? FileManager.default.removeItem(at: root) }
        let search = SearchModel()
        search.query.text = "x"
        search.schedule(root: root, files: ["big.txt"], buffers: [:], delay: .zero)
        try await settle(search)
        #expect(search.lineCount == SearchModel.cap)
        if case .done(_, _, _, let capped) = search.status { #expect(capped) } else { Issue.record("not done") }
    }
}
