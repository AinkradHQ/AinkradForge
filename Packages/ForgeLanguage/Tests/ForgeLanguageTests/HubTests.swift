import Foundation
import Testing

@testable import ForgeLanguage

@MainActor
@Suite("Language hub")
struct HubTests {
    /// End to end with the real sourcekit-lsp (skipped where it is not installed): open a file with an error,
    /// get the issue with its position; close it, the issue goes.
    @Test func sourcekitReportsAndClearsAnIssue() async throws {
        guard ShellEnvironment.locate("sourcekit-lsp") != nil else { return }
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("forge-lsp-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = "let x: Int = \"nope\"\n"
        try text.write(to: root.appending(path: "main.swift"), atomically: true, encoding: .utf8)

        let hub = LanguageHub()
        hub.begin(root: root)
        hub.opened(path: "main.swift", text: text)
        for _ in 0..<150 where hub.issues["main.swift"] == nil { try await Task.sleep(for: .milliseconds(100)) }
        let issue = try #require(hub.issues["main.swift"]?.first)
        #expect(issue.severity == .error)
        #expect(issue.start.line == 0)
        #expect(issue.message.contains("String"))
        #expect(hub.statuses["sourcekit-lsp"] == .ready)
        #expect(hub.errorCount == 1)

        hub.closed(path: "main.swift")
        for _ in 0..<50 where hub.issues["main.swift"] != nil { try await Task.sleep(for: .milliseconds(100)) }
        #expect(hub.issues["main.swift"] == nil)
        hub.end()
    }

    @Test func aMissingServerIsReportedNotInstalled() async throws {
        let hub = LanguageHub()
        hub.overrides["gopls"] = "/nonexistent/gopls"
        hub.begin(root: URL(fileURLWithPath: NSTemporaryDirectory()))
        hub.opened(path: "main.go", text: "package main\n")
        #expect(hub.statuses["gopls"] == .notInstalled)
    }
}
