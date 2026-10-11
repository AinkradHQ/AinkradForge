import Foundation
import Testing

@testable import ForgeFeature

@Suite("Text search")
struct TextSearchTests {
    private func regex(_ text: String, matchCase: Bool = false, wholeWord: Bool = false, regex: Bool = false) throws -> NSRegularExpression {
        try #require(try SearchQuery(text: text, matchCase: matchCase, wholeWord: wholeWord, regex: regex).compile())
    }

    @Test func everyMatchOnALineIsFoundWithItsLineNumber() throws {
        let text = "let a = isSelected\n\nif isSelected && !isSelected {}\n"
        let found = TextSearch.matches(in: text, regex: try regex("isSelected"))
        #expect(found.map(\.line) == [1, 3])
        #expect(found[1].ranges.count == 2)
        #expect(found[1].ranges[0] == NSRange(location: 3, length: 10))
    }

    @Test func togglesChangeWhatMatches() throws {
        let text = "Selected selected selectedRow"
        #expect(TextSearch.matches(in: text, regex: try regex("selected"))[0].ranges.count == 3)
        #expect(TextSearch.matches(in: text, regex: try regex("selected", matchCase: true))[0].ranges.count == 2)
        #expect(TextSearch.matches(in: text, regex: try regex("selected", wholeWord: true))[0].ranges.count == 2)
        #expect(TextSearch.matches(in: "a1 b22", regex: try regex("[a-z]\\d+", regex: true))[0].ranges.count == 2)
        // Without .*, regex characters are literal.
        #expect(TextSearch.matches(in: "a.b axb", regex: try regex("a.b"))[0].ranges.count == 1)
    }

    @Test func anInvalidRegexIsAMessageAndAnEmptyQueryIsNothing() throws {
        #expect(throws: FileOps.Failure.self) { try SearchQuery(text: "(", regex: true).compile() }
        #expect(try SearchQuery(text: "").compile() == nil)
    }

    @Test func replaceIsLiteralUnlessRegexAndCanPreserveCase() throws {
        let literal = TextSearch.replace(in: "a.b a.b", regex: try regex("a.b"), with: "$1", isRegex: false, preserveCase: false)
        #expect(literal.text == "$1 $1" && literal.count == 2)
        let groups = TextSearch.replace(
            in: "key=1", regex: try regex("(\\w+)=(\\d)", regex: true), with: "$2:$1", isRegex: true, preserveCase: false)
        #expect(groups.text == "1:key")
        let cased = TextSearch.replace(
            in: "isSelected IsSelected ISSELECTED", regex: try regex("isselected"), with: "isActive", isRegex: false,
            preserveCase: true)
        #expect(cased.text == "isActive IsActive ISACTIVE")
    }

    @Test func globsMatchPathsTheWayTheySay() {
        let sources = GlobSet("Sources/**, Tests/**")
        #expect(sources.matches("Sources/A/B.swift") && sources.matches("Tests/X.swift"))
        #expect(!sources.matches("Docs/Sources/A.swift"))
        let swift = GlobSet("*.swift")
        #expect(swift.matches("Sources/A.swift") && swift.matches("A.swift") && !swift.matches("A.swiftx"))
        let build = GlobSet(".build")
        #expect(build.matches(".build/x/y.o") && build.matches("Pkg/.build/z"))
        #expect(GlobSet("Sources/*.swift").matches("Sources/A.swift") && !GlobSet("Sources/*.swift").matches("Sources/A/B.swift"))
        #expect(GlobSet("  ").isEmpty)
    }

    @Test func linesAndWordsForReferences() {
        let text = "first\r\nlet isSelected = true\nlast"
        #expect(TextSearch.line(1, of: text) == "let isSelected = true")
        #expect(TextSearch.line(9, of: text) == "")
        #expect(TextSearch.word(in: "let isSelected = true", at: 6) == "isSelected")
        #expect(TextSearch.word(in: "let isSelected = true", at: 4) == "isSelected")
        #expect(TextSearch.word(in: "a + b", at: 2) == "")
    }

    @Test func hoverMarkdownSplitsCodeFromProse() {
        let blocks = HoverCard.blocks("```swift\nfunc bump(_ n: Int) -> Int\n```\n\nAdds **one**.\n")
        #expect(blocks.count == 2)
        #expect(blocks.first == .code("func bump(_ n: Int) -> Int"))
        guard case .prose(let prose) = blocks.last else {
            Testing.Issue.record("no prose")
            return
        }
        #expect(String(prose.characters) == "Adds one.")
    }
}
