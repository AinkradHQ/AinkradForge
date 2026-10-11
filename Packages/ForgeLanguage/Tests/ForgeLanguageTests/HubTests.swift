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

    /// Hover and definition across an edit the server has not been sent yet (the request flushes it); references
    /// in a package, once saved (sourcekit-lsp indexes the files on disk, so a loose file gets none).
    @Test func sourcekitAnswersHoverDefinitionAndReferences() async throws {
        guard ShellEnvironment.locate("sourcekit-lsp") != nil else { return }
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("forge-lsp-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = "/// Adds one.\nfunc bump(_ n: Int) -> Int { n + 1 }\n"
        try original.write(to: root.appending(path: "main.swift"), atomically: true, encoding: .utf8)
        try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"P\", targets: [.executableTarget(name: \"P\", path: \".\", sources: [\"main.swift\"])])\n"
            .write(to: root.appending(path: "Package.swift"), atomically: true, encoding: .utf8)

        let hub = LanguageHub()
        hub.begin(root: root)
        hub.opened(path: "main.swift", text: original)
        let edited = original + "let a = bump(1)\nlet b = bump(a)\n"
        hub.changed(path: "main.swift") { edited }

        // Line 2 is `let a = bump(1)`; character 9 is inside `bump`.
        var hover: String?
        for _ in 0..<100 where hover == nil {
            hover = await hub.hover(path: "main.swift", line: 2, character: 9)
            if hover == nil { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(hover?.contains("bump") == true)
        #expect(hover?.contains("Adds one") == true)

        let definitions = await hub.definition(path: "main.swift", line: 2, character: 9)
        #expect(definitions.first?.path == "main.swift")
        #expect(definitions.first?.start.line == 1)

        // References come from sourcekit's index, which reads the files on disk: save, then ask.
        try edited.write(to: root.appending(path: "main.swift"), atomically: true, encoding: .utf8)
        hub.saved(path: "main.swift")
        var references: [SymbolLocation] = []
        for _ in 0..<40 where references.count < 3 {
            references = await hub.references(path: "main.swift", line: 2, character: 9)
            if references.count < 3 { try await Task.sleep(for: .seconds(1)) }
        }
        #expect(Set(references.map(\.start.line)) == [1, 2, 3], "\(references.map { ($0.path, $0.start.line) })")
        hub.end()
    }

    /// Completion and signature help at the caret, the latest edit flushed first.
    @Test func sourcekitCompletesAndHelpsWithSignatures() async throws {
        guard ShellEnvironment.locate("sourcekit-lsp") != nil else { return }
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("forge-lsp-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = "func bump(_ n: Int, by step: Int) -> Int { n + step }\n"
        try original.write(to: root.appending(path: "main.swift"), atomically: true, encoding: .utf8)

        let hub = LanguageHub()
        hub.begin(root: root)
        hub.opened(path: "main.swift", text: original)
        for _ in 0..<150 where hub.statuses["sourcekit-lsp"] != .ready { try await Task.sleep(for: .milliseconds(100)) }
        #expect(hub.completionTriggers["sourcekit-lsp"]?.contains(".") == true)

        // Line 1: `let a = bum` — the caret after "bum".
        hub.changed(path: "main.swift") { original + "let a = bum" }
        let completions = await hub.completions(path: "main.swift", line: 1, character: 11)
        let bump = try #require(completions.first { $0.label.hasPrefix("bump") })
        #expect(bump.kind == .function)
        #expect(bump.insertText.hasPrefix("bump("))
        #expect(!bump.insertText.contains("${"))

        // Line 1: `let a = bump(1, ` — the caret on the second argument.
        hub.changed(path: "main.swift") { original + "let a = bump(1, " }
        let hint = try #require(await hub.signatureHelp(path: "main.swift", line: 1, character: 16))
        #expect(hint.label.hasPrefix("bump(_ n: Int, by: Int)"))
        let active = try #require(hint.activeParameter)
        #expect((hint.label as NSString).substring(with: active) == "by: Int")
        hub.end()
    }

    /// Rename, a quick fix and formatting, end to end — each comes back as changes Forge makes itself.
    @Test func sourcekitRenamesFixesAndFormats() async throws {
        guard ShellEnvironment.locate("sourcekit-lsp") != nil else { return }
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("forge-lsp-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = "func run() {\n    var count = 1\n    print(count + count)\n}\n"
        try text.write(to: root.appending(path: "main.swift"), atomically: true, encoding: .utf8)

        let hub = LanguageHub()
        hub.begin(root: root)
        hub.opened(path: "main.swift", text: text)
        for _ in 0..<150 where hub.issues["main.swift"] == nil { try await Task.sleep(for: .milliseconds(100)) }

        // `count` on line 1: three places, all in this file.
        let renamed = await hub.rename(path: "main.swift", line: 1, character: 9, to: "total")
        #expect(renamed["main.swift"]?.count == 3)
        let after = TextChange.apply(renamed["main.swift"] ?? [], to: text)
        #expect(after == "func run() {\n    var total = 1\n    print(total + total)\n}\n")

        // "never mutated; consider changing to 'let'" — its fix-it as a quick fix.
        let actions = await hub.codeActions(path: "main.swift", from: (1, 0), to: (2, 0))
        let fix = try #require(actions.first { $0.title.contains("let") }, "\(actions.map { ($0.title, $0.kind ?? "-") }) issues: \(hub.issues["main.swift"]?.map(\.message) ?? [])")
        #expect(fix.kind?.hasPrefix("quickfix") == true)
        let fixed = await hub.perform(fix, path: "main.swift")
        #expect(TextChange.apply(fixed["main.swift"] ?? [], to: text).contains("    let count = 1"))

        let messy = "func run( ) {\nlet  a=1\n    print(a)}\n"
        hub.changed(path: "main.swift") { messy }
        let formatting = await hub.format(path: "main.swift", tabSize: 4, insertSpaces: true)
        #expect(TextChange.apply(formatting, to: messy) == "func run() {\n    let a = 1\n    print(a)\n}\n")
        hub.end()
    }

    @Test func changesApplyAgainstTheOriginal() {
        let text = "let a = 1\nlet b = a + a\n"
        let changes = [
            TextChange(start: (0, 4), end: (0, 5), newText: "first"),
            TextChange(start: (1, 8), end: (1, 9), newText: "first"),
            TextChange(start: (1, 12), end: (1, 13), newText: "first"),
        ]
        #expect(TextChange.apply(changes, to: text) == "let first = 1\nlet b = first + first\n")
    }

    @Test func snippetsBecomeTheirDefaults() {
        #expect(Snippet.plain("start(at: ${1:date})$0") == "start(at: date)")
        #expect(Snippet.plain("bump(${1:n}, by: ${2:step})") == "bump(n, by: step)")
        #expect(Snippet.plain("cost: \\$${1:price}") == "cost: $price")
    }

    /// A path set in settings takes over at once: the running server stops and the next open uses the new place.
    @Test func aNewPathTakesOverAtOnce() async throws {
        guard ShellEnvironment.locate("sourcekit-lsp") != nil else { return }
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
        let hub = LanguageHub()
        hub.begin(root: root)
        hub.opened(path: "main.swift", text: "let a = 1\n")
        #expect(hub.statuses["sourcekit-lsp"] == .starting)
        hub.setOverride("sourcekit-lsp", path: "/nonexistent/sourcekit-lsp")
        #expect(hub.statuses["sourcekit-lsp"] == nil)
        hub.opened(path: "main.swift", text: "let a = 1\n")
        #expect(hub.statuses["sourcekit-lsp"] == .notInstalled)
        hub.setOverride("sourcekit-lsp", path: nil)
        hub.opened(path: "main.swift", text: "let a = 1\n")
        #expect(hub.statuses["sourcekit-lsp"] == .starting)
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
