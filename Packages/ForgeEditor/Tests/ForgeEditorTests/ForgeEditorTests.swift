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
}
