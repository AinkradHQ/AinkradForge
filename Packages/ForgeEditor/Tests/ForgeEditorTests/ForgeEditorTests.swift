import AppKit
import Testing

@testable import ForgeEditor

@Suite("ForgeEditor")
struct ForgeEditorTests {
    @Test func detectsLanguagesFromExtensionAndShebang() {
        #expect(EditorLanguage.detect(url: URL(fileURLWithPath: "/a/App.swift")).name == "Swift")
        #expect(EditorLanguage.detect(url: URL(fileURLWithPath: "/a/run"), prefix: "#!/bin/bash\n").name == "Bash")
        #expect(EditorLanguage.detect(url: URL(fileURLWithPath: "/a/notes.unknownext")).name == "Plaintext")
    }

    /// The editor sits over glass: its background must be transparent AND sRGB (a gray-colourspace clear
    /// crashes the minimap's brightness check — E1 spike).
    @Test func themeBackgroundIsTransparentSRGB() {
        let gray = NSColor.gray
        let colors = EditorColors(
            text: gray, insertionPoint: gray, selection: gray, lineHighlight: gray, keywords: gray, commands: gray,
            types: gray, attributes: gray, variables: gray, values: gray, numbers: gray, strings: gray, comments: gray)
        let background = colors.theme.background
        #expect(background.alphaComponent == 0)
        #expect(background.colorSpace == .sRGB)
    }

    /// Typing narrows completions: prefix matches first, then in-order letters; the server's order kept.
    @Test func suggestionsNarrowAsTheWordIsTyped() {
        func item(_ label: String) -> EditorSuggestion {
            EditorSuggestion(
                label: label, kind: .property, detail: nil, documentation: nil, insertText: label, filterText: label,
                replaceStart: nil, deprecated: false)
        }
        let all = ["state", "statusText", "lastUpdate", "restore()", "count"].map(item)
        #expect(EditorSuggestion.filter(all, prefix: "").count == 5)
        #expect(EditorSuggestion.filter(all, prefix: "st").map(\.label) == ["state", "statusText", "lastUpdate", "restore()"])
        #expect(EditorSuggestion.filter(all, prefix: "STA").map(\.label) == ["state", "statusText", "lastUpdate"])
        #expect(EditorSuggestion.filter(all, prefix: "xyz").isEmpty)
    }
}
