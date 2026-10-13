import Foundation
import LanguageServerProtocol
import Testing

@testable import ForgeLanguage

@Suite("Language core")
struct LanguageCoreTests {
    /// The breadcrumb's tail: the symbols around the caret, outermost first; none outside every symbol.
    @Test func enclosingSymbolsNestOutermostFirst() {
        func range(_ a: Int, _ b: Int) -> LSPRange {
            LSPRange(start: Position(line: a, character: 0), end: Position(line: b, character: 1))
        }
        let body = DocumentSymbol(name: "body", kind: .property, range: range(9, 22), selectionRange: range(9, 9))
        let row = DocumentSymbol(name: "SidebarRow", kind: .struct, range: range(4, 23), selectionRange: range(4, 4), children: [body])
        #expect(LanguageHub.enclosing([row], line: 20, character: 4) == ["SidebarRow", "body"])
        #expect(LanguageHub.enclosing([row], line: 6, character: 4) == ["SidebarRow"])
        #expect(LanguageHub.enclosing([row], line: 1, character: 0) == [])
    }

    /// Quick open's `@`: the outline flattened in order, each child after its parent and naming it.
    @Test func documentSymbolsFlattenParentFirst() {
        func range(_ a: Int, _ b: Int) -> LSPRange {
            LSPRange(start: Position(line: a, character: 4), end: Position(line: b, character: 1))
        }
        let body = DocumentSymbol(name: "body", kind: .property, range: range(9, 22), selectionRange: range(9, 9))
        let row = DocumentSymbol(name: "SidebarRow", kind: .struct, range: range(4, 23), selectionRange: range(4, 4), children: [body])
        let style = DocumentSymbol(name: "plain", kind: .enumMember, range: range(25, 25), selectionRange: range(25, 25))
        let flat = LanguageHub.flatten([row, style], path: "A.swift", container: nil)
        #expect(flat.map(\.name) == ["SidebarRow", "body", "plain"])
        #expect(flat.map(\.kind) == ["struct", "property", "case"])
        #expect(flat[1].container == "SidebarRow" && flat[1].line == 9 && flat[1].character == 4)
    }

    @Test func filesMapToTheirServerAndLanguageID() {
        #expect(LanguageRegistry.server(for: "Sources/A.swift")?.spec.id == "sourcekit-lsp")
        #expect(LanguageRegistry.server(for: "web/App.tsx")?.languageID == "typescriptreact")
        #expect(LanguageRegistry.server(for: "app/Http/Kernel.php")?.spec.id == "intelephense")
        #expect(LanguageRegistry.server(for: "README.md") == nil)
    }

    /// FD25: HTML, CSS (and SCSS / Less), JSON (and JSONC) and YAML, each under the languageId its server expects,
    /// with the npm package to install it from.
    @Test func webAndDataFilesMapToTheirServers() {
        let expected: [(String, String, String)] = [
            ("site/index.html", "vscode-html-language-server", "html"), ("a.htm", "vscode-html-language-server", "html"),
            ("s.css", "vscode-css-language-server", "css"), ("s.scss", "vscode-css-language-server", "scss"),
            ("s.less", "vscode-css-language-server", "less"), ("package.json", "vscode-json-language-server", "json"),
            (".vscode/settings.jsonc", "vscode-json-language-server", "jsonc"), ("ci.yml", "yaml-language-server", "yaml"),
            ("k8s/app.YAML", "yaml-language-server", "yaml"),
        ]
        for (path, server, languageID) in expected {
            let found = LanguageRegistry.server(for: path)
            #expect(found?.spec.id == server, "\(path)")
            #expect(found?.languageID == languageID, "\(path)")
            #expect(found?.spec.arguments == ["--stdio"])
        }
        #expect(LanguageRegistry.server(for: "a.css")?.spec.installHint == "npm i -g vscode-langservers-extracted")
        #expect(LanguageRegistry.server(for: "a.yaml")?.spec.installHint == "npm i -g yaml-language-server")
        // One server per extension.
        let extensions = LanguageRegistry.servers.flatMap(\.languageIDs.keys)
        #expect(extensions.count == Set(extensions).count)
    }

    /// E6: one silent restart; a second crash within five minutes stops the server; an older crash has aged out.
    @Test func aSecondCrashWithinFiveMinutesStopsTheServer() {
        let start = Date()
        var policy = CrashPolicy()
        let restarts = [0, 299].map { policy.crashed(at: start.addingTimeInterval($0)) }
        #expect(restarts == [true, false])
        var later = CrashPolicy()
        let spaced = [0, 301, 400].map { later.crashed(at: start.addingTimeInterval($0)) }
        #expect(spaced == [true, true, false])
        later.reset()
        let afterReset = later.crashed(at: start.addingTimeInterval(401))
        #expect(afterReset)
        #expect(CrashPolicy.describe(status: 3, bySignal: false) == "exit 3")
        #expect(CrashPolicy.describe(status: 11, bySignal: true) == "signal 11 (SEGV)")
        #expect(CrashPolicy.describe(status: 99, bySignal: true) == "signal 99")
    }

    /// `$/progress` folds into one status-bar line: the newest unfinished task, nil once all have ended.
    @Test func progressReportsFoldIntoOneLine() {
        var tracker = ProgressTracker()
        func kind(_ kind: String, _ fields: [String: LSPAny] = [:]) -> LSPAny { .hash(fields.merging(["kind": .string(kind)]) { a, _ in a }) }
        let lines = [
            tracker.update(token: "1", value: kind("begin", ["title": .string("Indexing")])),
            tracker.update(token: "1", value: kind("report", ["message": .string("412 / 1280")])),
            tracker.update(token: "2", value: kind("begin", ["title": .string("Loading"), "percentage": .number(40)])),
            tracker.update(token: "2", value: kind("end")),
            tracker.update(token: "9", value: .string("not progress")),
            tracker.update(token: "1", value: kind("end")),
        ]
        #expect(lines == ["Indexing", "Indexing 412 / 1280", "Loading 40%", "Indexing 412 / 1280", "Indexing 412 / 1280", nil])
    }

    @Test func positionsAreUTF16AndClamped() {
        // "é" is one UTF-16 unit, "🙂" two: LSP characters count code units, like NSRange.
        let index = LineIndex("let é = 1\nlet 🙂x = 2\n")
        #expect(index.lineCount == 3)
        #expect(index.offset(line: 1, character: 0) == 10)
        #expect(index.offset(line: 1, character: 6) == 16)  // after "let 🙂" (4 + 2 units)
        #expect(index.offset(line: 1, character: 999) == 21)  // clamped to the line's end
        #expect(index.offset(line: 9, character: 0) == 22)  // past the end → text length
        #expect(index.position(of: 16) == (1, 6))
        #expect(index.range(from: (0, 4), to: (0, 5)) == NSRange(location: 4, length: 1))
    }

    /// `go install` puts gopls in ~/go/bin, which is often not on PATH; it is still found.
    @Test func toolFoldersOffPathAreSearched() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard FileManager.default.isExecutableFile(atPath: "\(home)/go/bin/gopls") else { return }
        #expect(ShellEnvironment.locate("gopls") != nil)
    }
}
