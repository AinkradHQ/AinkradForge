import AppKit
// CodeEdit predates strict concurrency; its callbacks all arrive on the main thread.
@preconcurrency internal import CodeEditLanguages
@preconcurrency internal import CodeEditSourceEditor
import SwiftUI

// No public type here stores a CodeEdit type: a client of a non-resilient module needs the layout of every
// stored property, and CodeEdit's types pull in its C modules (TreeSitter), which Xcode cannot resolve from
// the app's project. Hence the language is kept as its id, and the editor view renders through `AnyView`.

/// A file's language, for highlighting and the status bar.
public struct EditorLanguage: Equatable, Sendable {
    /// `TreeSitterLanguage` raw value, e.g. "swift".
    let id: String
    /// e.g. "Swift", "Json".
    public let name: String

    /// From the file extension (or shebang in `prefix`); plain text when unknown.
    public static func detect(url: URL, prefix: String? = nil) -> EditorLanguage {
        let code = CodeLanguage.detectLanguageFrom(url: url, prefixBuffer: prefix)
        return EditorLanguage(id: code.id.rawValue, name: code.tsName.capitalized)
    }

    var code: CodeLanguage {
        CodeLanguage.allLanguages.first { $0.id.rawValue == id } ?? .default
    }
}

/// Every colour the editor draws with. Plain `NSColor`s, so the host theme mapping lives with the caller.
public struct EditorColors: Equatable, Sendable {
    public var text, insertionPoint, selection, lineHighlight: NSColor
    public var keywords, commands, types, attributes, variables, values, numbers, strings, comments: NSColor

    public init(
        text: NSColor, insertionPoint: NSColor, selection: NSColor, lineHighlight: NSColor, keywords: NSColor,
        commands: NSColor, types: NSColor, attributes: NSColor, variables: NSColor, values: NSColor, numbers: NSColor,
        strings: NSColor, comments: NSColor
    ) {
        self.text = text
        self.insertionPoint = insertionPoint
        self.selection = selection
        self.lineHighlight = lineHighlight
        self.keywords = keywords
        self.commands = commands
        self.types = types
        self.attributes = attributes
        self.variables = variables
        self.values = values
        self.numbers = numbers
        self.strings = strings
        self.comments = comments
    }

    var theme: EditorTheme {
        EditorTheme(
            text: .init(color: text), insertionPoint: insertionPoint, invisibles: .init(color: text.withAlphaComponent(0.25)),
            // sRGB, not `.clear`: a gray-colourspace clear trips the minimap's brightness check.
            background: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0),
            lineHighlight: lineHighlight, selection: selection,
            keywords: .init(color: keywords), commands: .init(color: commands), types: .init(color: types),
            attributes: .init(color: attributes), variables: .init(color: variables), values: .init(color: values),
            numbers: .init(color: numbers), strings: .init(color: strings), characters: .init(color: strings),
            comments: .init(color: comments, italic: true))
    }
}

/// Edits `storage` in place (a large file is never copied per keystroke). Transparent, so the window's
/// surface — Neon fill or Liquid Glass — shows through.
public struct ForgeCodeEditor: View {
    let storage: NSTextStorage
    let language: EditorLanguage
    let colors: EditorColors
    let fontSize: CGFloat
    let insets: NSEdgeInsets
    let onEdit: () -> Void
    /// 1-based line and column of the first caret.
    let onCursor: (Int, Int) -> Void
    /// A 1-based line to put the caret on and scroll to; `onGoToLineHandled` is called once it is done.
    let goToLine: Int?
    let onGoToLineHandled: () -> Void
    /// The caret moved while this editor has keyboard focus — the user is working here (not a load).
    let onFocusedCaret: () -> Void

    public init(
        storage: NSTextStorage, language: EditorLanguage, colors: EditorColors, fontSize: CGFloat,
        insets: NSEdgeInsets, onEdit: @escaping () -> Void, onCursor: @escaping (Int, Int) -> Void,
        goToLine: Int? = nil, onGoToLineHandled: @escaping () -> Void = {},
        onFocusedCaret: @escaping () -> Void = {}
    ) {
        self.storage = storage
        self.language = language
        self.colors = colors
        self.fontSize = fontSize
        self.insets = insets
        self.onEdit = onEdit
        self.onCursor = onCursor
        self.goToLine = goToLine
        self.onGoToLineHandled = onGoToLineHandled
        self.onFocusedCaret = onFocusedCaret
    }

    public var body: AnyView {
        AnyView(
            EditorHost(
                storage: storage, language: language, colors: colors, fontSize: fontSize, insets: insets,
                onEdit: onEdit, onCursor: onCursor, goToLine: goToLine, onGoToLineHandled: onGoToLineHandled,
                onFocusedCaret: onFocusedCaret))
    }
}

struct EditorHost: View {
    let storage: NSTextStorage
    let language: EditorLanguage
    let colors: EditorColors
    let fontSize: CGFloat
    let insets: NSEdgeInsets
    let onEdit: () -> Void
    /// 1-based line and column of the first caret.
    let onCursor: (Int, Int) -> Void
    let goToLine: Int?
    let onGoToLineHandled: () -> Void
    let onFocusedCaret: () -> Void
    @State private var state = SourceEditorState()
    @State private var coordinator = Coordinator()

    var body: some View {
        SourceEditor(
            storage,
            language: language.code,
            configuration: SourceEditorConfiguration(
                appearance: .init(
                    theme: colors.theme, font: .monospacedSystemFont(ofSize: fontSize, weight: .regular),
                    lineHeightMultiple: 1.45, wrapLines: false),
                layout: .init(contentInsets: insets),
                peripherals: .init(showMinimap: false)),
            state: $state,
            coordinators: [coordinator]
        )
        .onAppear {
            coordinator.onEdit = onEdit
            coordinator.onCursor = onCursor
            coordinator.onFocusedCaret = onFocusedCaret
            go(to: goToLine)
        }
        .onChange(of: goToLine) { _, line in go(to: line) }
    }

    /// Through the controller, not `state.cursorPositions`: CodeEdit's state diff compares the new positions
    /// with themselves, so a caret set through state is never applied.
    private func go(to line: Int?) {
        guard let line else { return }
        // One turn later: on first appearance the controller has not loaded its view yet.
        DispatchQueue.main.async {
            coordinator.controller?.setCursorPositions([CursorPosition(line: line, column: 1)], scrollToVisible: true)
            onGoToLineHandled()
        }
    }

    /// Drops the scroll view's opaque background (it paints `textBackgroundColor` even when the theme
    /// background is clear) and reports edits and the caret.
    @MainActor
    final class Coordinator: @preconcurrency TextViewCoordinator {
        var onEdit: () -> Void = {}
        var onCursor: (Int, Int) -> Void = { _, _ in }
        var onFocusedCaret: () -> Void = {}
        weak var controller: TextViewController?

        /// `prepareCoordinator` runs before the controller loads its view (`scrollView`, implicitly unwrapped, is
        /// still nil), and `viewDidAppear` does not reliably fire inside a SwiftUI host — so one run-loop turn later.
        func prepareCoordinator(controller: TextViewController) {
            self.controller = controller
            DispatchQueue.main.async { [weak controller] in
                guard let scrollView = controller?.scrollView else { return }
                scrollView.drawsBackground = false
                scrollView.contentView.drawsBackground = false
            }
        }

        func textViewDidChangeText(controller: TextViewController) { onEdit() }

        func textViewDidChangeSelection(controller: TextViewController, newPositions: [CursorPosition]) {
            if let first = newPositions.first { onCursor(first.start.line, first.start.column) }
            if let textView = controller.textView, textView.window?.firstResponder === textView { onFocusedCaret() }
        }
    }
}
