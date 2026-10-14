import AppKit
import CodeEditTextView
import SwiftUI
import XCTest

@testable import ForgeEditor

/// ⌘Z survives the editor being rebuilt, as Forge does on every tab switch and outside reload (E1D5 FD61).
/// XCTest for the same reason as `RenderingTests`: the editor's main-queue work must run.
@MainActor
final class UndoHistoryTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
    }

    /// Mounts an editor on `storage` (a fresh view, as `.id` change or tab switch makes) and returns its text view.
    private func mount(_ storage: NSTextStorage) throws -> TextView {
        windows.forEach { $0.contentView = nil; $0.orderOut(nil) }
        let gray = NSColor.gray
        let colors = EditorColors(
            text: gray, insertionPoint: gray, selection: gray, lineHighlight: gray, keywords: gray, commands: gray,
            types: gray, attributes: gray, variables: gray, values: gray, numbers: gray, strings: gray, comments: gray)
        let host = NSHostingView(
            rootView: ForgeCodeEditor(
                storage: storage, language: .detect(url: URL(fileURLWithPath: "/a.swift")), colors: colors,
                insets: NSEdgeInsets(), onEdit: {}, onCursor: { _, _ in }))
        let window = NSWindow(
            contentRect: NSRect(x: -3000, y: -3000, width: 500, height: 300), styleMask: .borderless,
            backing: .buffered, defer: false)
        window.contentView = host
        window.orderBack(nil)
        windows.append(window)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        func textView(in view: NSView) -> TextView? {
            (view as? TextView) ?? view.subviews.lazy.compactMap(textView(in:)).first
        }
        return try XCTUnwrap(textView(in: host))
    }

    func testUndoSurvivesARebuiltEditor() throws {
        let storage = NSTextStorage(string: "let a = 1\n")
        try mount(storage).replaceCharacters(in: NSRange(location: 0, length: 0), with: "// typed\n")
        XCTAssertEqual(storage.string, "// typed\nlet a = 1\n")

        let rebuilt = try mount(storage)
        XCTAssertEqual(rebuilt.undoManager?.canUndo, true, "the rebuilt editor lost the history")
        rebuilt.undoManager?.undo()
        XCTAssertEqual(storage.string, "let a = 1\n")
    }

    func testAnOutsideReloadIsOneUndoableStep() throws {
        let storage = NSTextStorage(string: "let a = 1\n")
        try mount(storage).replaceCharacters(in: NSRange(location: 0, length: 0), with: "// typed\n")
        windows.forEach { $0.contentView = nil }
        // No editor mounted (a background tab): the agent rewrites the file and Forge reloads it.
        EditorUndo.replace(storage, with: "let b = 2\n")
        XCTAssertEqual(storage.string, "let b = 2\n")

        let rebuilt = try mount(storage)
        rebuilt.undoManager?.undo()
        XCTAssertEqual(storage.string, "// typed\nlet a = 1\n", "⌘Z must take the reload back first")
        rebuilt.undoManager?.undo()
        XCTAssertEqual(storage.string, "let a = 1\n", "the history before the reload must still apply")
        rebuilt.undoManager?.redo()
        XCTAssertEqual(storage.string, "// typed\nlet a = 1\n")
    }
}
