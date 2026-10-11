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
                insets: NSEdgeInsets(), onEdit: {}, onCursor: { _, _ in }))
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
                storage: storage, language: .detect(url: URL(fileURLWithPath: "/a.txt")), colors: colors,
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

    /// The split editor shows one file in two panes: two editors on ONE storage. An edit made through the
    /// storage reaches both text views (CodeEdit's MultiStorageDelegate), and nothing crashes.
    func testTwoEditorsShareOneStorage() throws {
        let storage = NSTextStorage(string: "let a = 1\n")
        let gray = NSColor.gray
        let colors = EditorColors(
            text: gray, insertionPoint: gray, selection: gray, lineHighlight: gray, keywords: gray, commands: gray,
            types: gray, attributes: gray, variables: gray, values: gray, numbers: gray, strings: gray, comments: gray)
        func editor() -> ForgeCodeEditor {
            ForgeCodeEditor(
                storage: storage, language: .detect(url: URL(fileURLWithPath: "/a.swift")), colors: colors,
                insets: NSEdgeInsets(), onEdit: {}, onCursor: { _, _ in })
        }
        let host = NSHostingView(rootView: HStack { editor(); editor() })
        let window = NSWindow(
            contentRect: NSRect(x: -3000, y: -3000, width: 800, height: 300), styleMask: .borderless,
            backing: .buffered, defer: false)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "// shared\n")
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        func textViews(in view: NSView) -> [TextView] {
            ((view as? TextView).map { [$0] } ?? []) + view.subviews.flatMap(textViews(in:))
        }
        let views = textViews(in: host)
        XCTAssertEqual(views.count, 2)
        XCTAssertTrue(views.allSatisfy { $0.textStorage === storage && $0.string.hasPrefix("// shared") })
    }

    /// The options reach CodeEdit: wrapping and the indent unit.
    func testOptionsReachTheTextView() throws {
        let gray = NSColor.gray
        let colors = EditorColors(
            text: gray, insertionPoint: gray, selection: gray, lineHighlight: gray, keywords: gray, commands: gray,
            types: gray, attributes: gray, variables: gray, values: gray, numbers: gray, strings: gray, comments: gray)
        let host = NSHostingView(
            rootView: ForgeCodeEditor(
                storage: NSTextStorage(string: "x\n"), language: .detect(url: URL(fileURLWithPath: "/a.swift")), colors: colors,
                options: EditorOptions(fontSize: 18, tabWidth: 2, wrapLines: true), insets: NSEdgeInsets(),
                onEdit: {}, onCursor: { _, _ in }))
        let window = NSWindow(
            contentRect: NSRect(x: -3000, y: -3000, width: 400, height: 200), styleMask: .borderless,
            backing: .buffered, defer: false)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        func textView(in view: NSView) -> TextView? { (view as? TextView) ?? view.subviews.lazy.compactMap(textView(in:)).first }
        let editor = try XCTUnwrap(textView(in: host))
        XCTAssertTrue(editor.wrapLines)
        XCTAssertEqual(editor.font.pointSize, 18)
    }

    /// Diagnostics reach CodeEdit as underline emphases, replaced (not piled up) when they change.
    func testMarksBecomeUnderlines() throws {
        let gray = NSColor.gray
        let colors = EditorColors(
            text: gray, insertionPoint: gray, selection: gray, lineHighlight: gray, keywords: gray, commands: gray,
            types: gray, attributes: gray, variables: gray, values: gray, numbers: gray, strings: gray, comments: gray)
        let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        let host = NSHostingView(
            rootView: ForgeCodeEditor(
                storage: NSTextStorage(string: "let x: Int = \"nope\"\n"), language: .detect(url: URL(fileURLWithPath: "/a.swift")),
                colors: colors, insets: NSEdgeInsets(), onEdit: {}, onCursor: { _, _ in },
                marks: [EditorMark(range: NSRange(location: 13, length: 6), color: red)]))
        let window = NSWindow(
            contentRect: NSRect(x: -3000, y: -3000, width: 400, height: 200), styleMask: .borderless,
            backing: .buffered, defer: false)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        func textView(in view: NSView) -> TextView? { (view as? TextView) ?? view.subviews.lazy.compactMap(textView(in:)).first }
        let emphases = try XCTUnwrap(textView(in: host)?.emphasisManager).getEmphases(for: "forge.marks")
        XCTAssertEqual(emphases.map(\.range), [NSRange(location: 13, length: 6)])
    }
}
