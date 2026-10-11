import Foundation
import Testing

@testable import ForgeFeature

@Suite("Terminal links")
struct TerminalLinkTests {
    @Test func compilerPathsKeepTheirLine() {
        #expect(TerminalLink.parse("/w/Sources/A.swift:12:5") == .file(path: "/w/Sources/A.swift", line: 12))
        #expect(TerminalLink.parse("./src/a.ts:3") == .file(path: "./src/a.ts", line: 3))
        #expect(TerminalLink.parse("/w/Makefile") == .file(path: "/w/Makefile", line: nil))
        #expect(TerminalLink.parse("~/notes.md", home: "/Users/me") == .file(path: "/Users/me/notes.md", line: nil))
        #expect(TerminalLink.parse("file:///w/a.swift") == .file(path: "/w/a.swift", line: nil))
        #expect(TerminalLink.parse("https://example.com/x") == .url(URL(string: "https://example.com/x")!))
        #expect(TerminalLink.parse("not a link") == nil)
    }

    @MainActor
    @Test func aWorkspaceFileOpensAtItsLine() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("forge-link-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root.appending(path: "Sources"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "a\nb\nc\n".write(to: root.appending(path: "Sources/A.swift"), atomically: true, encoding: .utf8)
        let model = ForgeModel(store: ForgeStore(documents: MemoryDocs()))
        await model.start(launch: root.path)
        model.openTerminalLink(root.appending(path: "Sources/A.swift").path + ":3:1")
        #expect(model.tabs.active == "Sources/A.swift")
        #expect(model.pendingLine == 3)
    }
}
