import AppKit
import CodeEditSourceEditor
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

    /// Completion opens inside a word or after a trigger, never on a number (E0 FD22) or after "(" (E0 FD15).
    @MainActor @Test func completionStartsOnWordsNotNumbers() {
        func start(_ text: String) -> Int? {
            EditorHost.Coordinator.completionStart(in: text as NSString, caret: (text as NSString).length, triggers: ["."])
        }
        #expect(start("greet(times: gr") == 13)
        #expect(start("greeter.") == 8)
        #expect(start("greet(times: 2") == nil)
        #expect(start("let x = 42") == nil)
        #expect(start("0x1F") == nil)
        #expect(start("int32") == 0)
        #expect(start("greet(") == nil)
    }

    /// The completion panel takes Forge's finish, and its footer shows only with documentation — not the label
    /// again under a separator (FD5).
    @Test func completionPanelTakesTheSkinAndDropsTheBareFooter() {
        func entry(documentation: String?) -> SuggestionEntry {
            SuggestionEntry(
                suggestion: EditorSuggestion(
                    label: "state", kind: .property, detail: nil, documentation: documentation, insertText: "state",
                    filterText: "state", replaceStart: nil, deprecated: false),
                colors: nil)
        }
        #expect(entry(documentation: nil).sourcePreview == nil)
        #expect(entry(documentation: "The state.").sourcePreview == "state")

        let panel = EditorPanelStyle(background: .black, selection: .blue, cornerRadius: 14).suggestionPanelStyle
        #expect(panel == SuggestionPanelStyle(background: .black, selectedRowBackground: .blue, cornerRadius: 14))
    }
}

/// Mockup 09: ⌥-hover shows the card at once; otherwise the pointer rests half a second first.
@MainActor
@Test func optionHoverShowsAtOnce() {
    #expect(HoverTracker.delay(for: [.option]) == .zero)
    #expect(HoverTracker.delay(for: [.option, .shift]) == .zero)
    #expect(HoverTracker.delay(for: []) == .milliseconds(500))
}
