import Foundation
import Testing

@testable import ForgeLanguage

@Suite("Language core")
struct LanguageCoreTests {
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
