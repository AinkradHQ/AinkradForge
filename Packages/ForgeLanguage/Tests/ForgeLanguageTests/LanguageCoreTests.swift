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
