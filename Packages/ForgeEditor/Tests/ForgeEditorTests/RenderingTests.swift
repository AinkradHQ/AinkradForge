import AppKit
import CodeEditTextView
import SwiftUI
import XCTest

@testable import ForgeEditor

/// The editor as Forge hosts it — SwiftUI, in a window — must highlight and must not paint a background.
/// Both broke silently before: CodeEditLanguages 0.1.21 highlights nothing (every token stays the text colour),
/// and the scroll view paints an opaque `textBackgroundColor` over the glass unless told not to.
///
/// XCTest, not Swift Testing: a Swift Testing `@MainActor` test runs as a job ON the main dispatch queue, so
/// spinning the run loop inside it never runs the editor's own main-queue work (highlight results, our
/// deferred background fix). XCTest calls a test synchronously on the main thread, where it does.
@MainActor
final class RenderingTests: XCTestCase {
    func testHighlightsAndStaysTransparent() throws {
        let storage = NSTextStorage(string: "// a comment\nlet x = 1\n")
        let text = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let keyword = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
        let colors = EditorColors(
            text: text, insertionPoint: text, selection: text, lineHighlight: .clear, keywords: keyword,
            commands: text, types: text, attributes: text, variables: text, values: text, numbers: text,
            strings: text, comments: text)
        let host = NSHostingView(
            rootView: ForgeCodeEditor(
                storage: storage, language: .detect(url: URL(fileURLWithPath: "/a.swift")), colors: colors,
                fontSize: 13, insets: NSEdgeInsets(), onEdit: {}, onCursor: { _, _ in }))
        let window = NSWindow(
            contentRect: NSRect(x: -3000, y: -3000, width: 500, height: 300), styleMask: .borderless,
            backing: .buffered, defer: false)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        host.display()
        RunLoop.main.run(until: Date().addingTimeInterval(2))

        func scrollView(in view: NSView) -> NSScrollView? {
            (view as? NSScrollView) ?? view.subviews.lazy.compactMap(scrollView(in:)).first
        }
        let scroll = try XCTUnwrap(scrollView(in: host))
        XCTAssertFalse(scroll.drawsBackground)
        XCTAssertFalse(scroll.contentView.drawsBackground)
        let editor = try XCTUnwrap(scroll.documentView as? TextView)
        XCTAssertTrue(editor.textStorage === storage, "the editor must edit the document's storage in place")
        let letColor = storage.attribute(.foregroundColor, at: (storage.string as NSString).range(of: "let").location, effectiveRange: nil) as? NSColor
        XCTAssertEqual(letColor, keyword, "`let` was not highlighted as a keyword")
    }

    /// The caret lands on the requested line (CodeEdit's own state path would silently drop it).
    func testGoToLineMovesTheCaret() throws {
        let storage = NSTextStorage(string: (1...300).map { "line \($0)" }.joined(separator: "\n"))
        let gray = NSColor.gray
        let colors = EditorColors(
            text: gray, insertionPoint: gray, selection: gray, lineHighlight: gray, keywords: gray, commands: gray,
            types: gray, attributes: gray, variables: gray, values: gray, numbers: gray, strings: gray, comments: gray)
        var caretLine = 0
        var handled = false
        let host = NSHostingView(
            rootView: ForgeCodeEditor(
                storage: storage, language: .detect(url: URL(fileURLWithPath: "/a.txt")), colors: colors, fontSize: 13,
                insets: NSEdgeInsets(), onEdit: {}, onCursor: { line, _ in caretLine = line },
                goToLine: 250, onGoToLineHandled: { handled = true }))
        let window = NSWindow(
            contentRect: NSRect(x: -3000, y: -3000, width: 500, height: 300), styleMask: .borderless,
            backing: .buffered, defer: false)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        XCTAssertTrue(handled)
        XCTAssertEqual(caretLine, 250)
    }
}
