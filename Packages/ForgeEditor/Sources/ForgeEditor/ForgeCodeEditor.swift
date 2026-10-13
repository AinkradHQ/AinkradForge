import AppKit
// CodeEdit predates strict concurrency; its callbacks all arrive on the main thread.
@preconcurrency internal import CodeEditLanguages
@preconcurrency internal import CodeEditSourceEditor
@preconcurrency internal import CodeEditTextView
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
    /// The completion panel's finish; nil keeps CodeEdit's default.
    public var completionPanel: EditorPanelStyle?

    public init(
        text: NSColor, insertionPoint: NSColor, selection: NSColor, lineHighlight: NSColor, keywords: NSColor,
        commands: NSColor, types: NSColor, attributes: NSColor, variables: NSColor, values: NSColor, numbers: NSColor,
        strings: NSColor, comments: NSColor, completionPanel: EditorPanelStyle? = nil
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
        self.completionPanel = completionPanel
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

/// A floating panel's finish: its fill, the selected row's fill and its corner radius.
public struct EditorPanelStyle: Equatable, Sendable {
    public var background, selection: NSColor
    public var cornerRadius: CGFloat

    public init(background: NSColor, selection: NSColor, cornerRadius: CGFloat) {
        self.background = background
        self.selection = selection
        self.cornerRadius = cornerRadius
    }

    var suggestionPanelStyle: SuggestionPanelStyle {
        SuggestionPanelStyle(background: background, selectedRowBackground: selection, cornerRadius: cornerRadius)
    }
}

/// The user's editor settings.
public struct EditorOptions: Equatable, Sendable {
    public var fontSize: Double
    public var tabWidth: Int
    /// Tab inserts spaces (`tabWidth` of them) rather than a tab character.
    public var insertSpaces: Bool
    public var wrapLines: Bool
    public var showMinimap: Bool
    public var showInvisibles: Bool

    public init(
        fontSize: Double = 13, tabWidth: Int = 4, insertSpaces: Bool = true, wrapLines: Bool = false,
        showMinimap: Bool = false, showInvisibles: Bool = false
    ) {
        self.fontSize = fontSize
        self.tabWidth = tabWidth
        self.insertSpaces = insertSpaces
        self.wrapLines = wrapLines
        self.showMinimap = showMinimap
        self.showInvisibles = showInvisibles
    }
}

/// A range of the buffer to mark: underlined (a diagnostic, in its severity's colour), washed (a search match —
/// a soft fill behind its text), or line-washed (a change made outside Forge — its lines filled edge to edge).
public struct EditorMark: Equatable, Sendable {
    public let range: NSRange
    public let color: NSColor
    public let isWash: Bool
    /// Wash every line the range touches across the editor's full width, not just the text.
    public let isLineWash: Bool

    public init(range: NSRange, color: NSColor, isWash: Bool = false, isLineWash: Bool = false) {
        self.range = range
        self.color = color
        self.isWash = isWash
        self.isLineWash = isLineWash
    }
}

/// A definition to jump to. The caller opens it (another file, a preview tab).
public struct EditorLink: Sendable {
    /// Absolute.
    public let path: String
    /// 1-based.
    public let line: Int
    public let label: String
    public let preview: String

    public init(path: String, line: Int, label: String, preview: String) {
        self.path = path
        self.line = line
        self.label = label
        self.preview = preview
    }
}

/// Edits `storage` in place (a large file is never copied per keystroke). Transparent, so the window's
/// surface — Neon fill or Liquid Glass — shows through.
public struct ForgeCodeEditor: View {
    let storage: NSTextStorage
    let language: EditorLanguage
    let colors: EditorColors
    let options: EditorOptions
    let insets: NSEdgeInsets
    let onEdit: () -> Void
    /// 1-based line and column of the first caret.
    let onCursor: (Int, Int) -> Void
    /// A 1-based line to put the caret on and scroll to; `onGoToLineHandled` is called once it is done.
    let goToLine: Int?
    let onGoToLineHandled: () -> Void
    /// Take keyboard focus (a file opened from the palette); `onFocusHandled` is called once it is done.
    let focus: Bool
    let onFocusHandled: () -> Void
    /// The caret moved while this editor has keyboard focus — the user is working here (not a load).
    let onFocusedCaret: () -> Void
    /// Ranges to underline (diagnostics).
    let marks: [EditorMark]
    /// ⌘-click: the definitions of the symbol at a UTF-16 offset; `onOpenLink` opens the one chosen.
    let definitions: ((Int) async -> [EditorLink])?
    let onOpenLink: (EditorLink) -> Void
    /// The pointer rests on a word (its offset and rect, top-left origin in this view), or stopped.
    let onHover: ((Int, CGRect)?) -> Void
    /// Completions at a UTF-16 offset, shown in CodeEditSourceEditor's suggestion window after a trigger
    /// character (or ⌃Space / Esc), narrowed as the word is typed.
    let suggest: ((Int) async -> [EditorSuggestion])?
    let suggestionTriggers: Set<String>
    /// Typing a signature trigger ("(", ","), or moving the caret while `signatureShown`, reports the caret's
    /// offset and rect; the caller asks its server and shows (or hides) the hint.
    let signatureTriggers: Set<String>
    let signatureShown: Bool
    let onSignature: ((Int, CGRect)?) -> Void
    /// Edits to make through the editor; `onEditsApplied` reports each id once made.
    let edits: EditorEdits?
    let onEditsApplied: (Int) -> Void
    /// A menu to open at the caret, and its pick.
    let menu: EditorMenu?
    let onMenuPick: (Int?) -> Void
    /// Where the caret is drawn after each move (top-left origin, this view), and where its line's text ends
    /// (x), for anchoring a field or a note to it.
    let onCaretRect: (CGRect, CGFloat) -> Void
    /// Change marks in the gutter; a click reports the mark's tag and rect.
    let lineMarks: [EditorLineMark]
    let onLineMarkClick: (Int, CGRect) -> Void
    /// A 1-based line to follow: its text's rect (this view, top-left origin) is reported whenever it moves —
    /// scrolling, layout, edits — and nil when it is off screen or gone.
    let anchorLine: Int?
    let onAnchor: (CGRect?) -> Void
    /// The first selection's UTF-16 range, after every change of it.
    let onSelection: (NSRange) -> Void

    public init(
        storage: NSTextStorage, language: EditorLanguage, colors: EditorColors, options: EditorOptions = EditorOptions(),
        insets: NSEdgeInsets, onEdit: @escaping () -> Void, onCursor: @escaping (Int, Int) -> Void,
        goToLine: Int? = nil, onGoToLineHandled: @escaping () -> Void = {},
        focus: Bool = false, onFocusHandled: @escaping () -> Void = {},
        onFocusedCaret: @escaping () -> Void = {}, marks: [EditorMark] = [],
        definitions: ((Int) async -> [EditorLink])? = nil, onOpenLink: @escaping (EditorLink) -> Void = { _ in },
        onHover: @escaping ((Int, CGRect)?) -> Void = { _ in },
        suggest: ((Int) async -> [EditorSuggestion])? = nil, suggestionTriggers: Set<String> = [],
        signatureTriggers: Set<String> = [], signatureShown: Bool = false,
        onSignature: @escaping ((Int, CGRect)?) -> Void = { _ in },
        edits: EditorEdits? = nil, onEditsApplied: @escaping (Int) -> Void = { _ in },
        menu: EditorMenu? = nil, onMenuPick: @escaping (Int?) -> Void = { _ in },
        onCaretRect: @escaping (CGRect, CGFloat) -> Void = { _, _ in },
        lineMarks: [EditorLineMark] = [], onLineMarkClick: @escaping (Int, CGRect) -> Void = { _, _ in },
        anchorLine: Int? = nil, onAnchor: @escaping (CGRect?) -> Void = { _ in },
        onSelection: @escaping (NSRange) -> Void = { _ in }
    ) {
        self.storage = storage
        self.language = language
        self.colors = colors
        self.options = options
        self.insets = insets
        self.onEdit = onEdit
        self.onCursor = onCursor
        self.goToLine = goToLine
        self.onGoToLineHandled = onGoToLineHandled
        self.focus = focus
        self.onFocusHandled = onFocusHandled
        self.onFocusedCaret = onFocusedCaret
        self.marks = marks
        self.definitions = definitions
        self.onOpenLink = onOpenLink
        self.onHover = onHover
        self.suggest = suggest
        self.suggestionTriggers = suggestionTriggers
        self.signatureTriggers = signatureTriggers
        self.signatureShown = signatureShown
        self.onSignature = onSignature
        self.edits = edits
        self.onEditsApplied = onEditsApplied
        self.menu = menu
        self.onMenuPick = onMenuPick
        self.onCaretRect = onCaretRect
        self.lineMarks = lineMarks
        self.onLineMarkClick = onLineMarkClick
        self.anchorLine = anchorLine
        self.onAnchor = onAnchor
        self.onSelection = onSelection
    }

    public var body: AnyView {
        AnyView(
            EditorHost(
                storage: storage, language: language, colors: colors, options: options, insets: insets,
                onEdit: onEdit, onCursor: onCursor, goToLine: goToLine, onGoToLineHandled: onGoToLineHandled,
                focus: focus, onFocusHandled: onFocusHandled, onFocusedCaret: onFocusedCaret, marks: marks, definitions: definitions, onOpenLink: onOpenLink,
                onHover: onHover, suggest: suggest, suggestionTriggers: suggestionTriggers,
                signatureTriggers: signatureTriggers, signatureShown: signatureShown, onSignature: onSignature,
                edits: edits, onEditsApplied: onEditsApplied, menu: menu, onMenuPick: onMenuPick, onCaretRect: onCaretRect,
                lineMarks: lineMarks, onLineMarkClick: onLineMarkClick, anchorLine: anchorLine, onAnchor: onAnchor,
                onSelection: onSelection))
    }
}

struct EditorHost: View {
    let storage: NSTextStorage
    let language: EditorLanguage
    let colors: EditorColors
    let options: EditorOptions
    let insets: NSEdgeInsets
    let onEdit: () -> Void
    /// 1-based line and column of the first caret.
    let onCursor: (Int, Int) -> Void
    let goToLine: Int?
    let onGoToLineHandled: () -> Void
    let focus: Bool
    let onFocusHandled: () -> Void
    let onFocusedCaret: () -> Void
    let marks: [EditorMark]
    let definitions: ((Int) async -> [EditorLink])?
    let onOpenLink: (EditorLink) -> Void
    let onHover: ((Int, CGRect)?) -> Void
    let suggest: ((Int) async -> [EditorSuggestion])?
    let suggestionTriggers: Set<String>
    let signatureTriggers: Set<String>
    let signatureShown: Bool
    let onSignature: ((Int, CGRect)?) -> Void
    let edits: EditorEdits?
    let onEditsApplied: (Int) -> Void
    let menu: EditorMenu?
    let onMenuPick: (Int?) -> Void
    let onCaretRect: (CGRect, CGFloat) -> Void
    let lineMarks: [EditorLineMark]
    let onLineMarkClick: (Int, CGRect) -> Void
    let anchorLine: Int?
    let onAnchor: (CGRect?) -> Void
    let onSelection: (NSRange) -> Void
    @State private var state = SourceEditorState()
    @State private var coordinator = Coordinator()

    var body: some View {
        SourceEditor(
            storage,
            language: language.code,
            configuration: SourceEditorConfiguration(
                appearance: .init(
                    theme: colors.theme, font: .monospacedSystemFont(ofSize: options.fontSize, weight: .regular),
                    lineHeightMultiple: 1.45, wrapLines: options.wrapLines, tabWidth: options.tabWidth,
                    suggestionPanelStyle: colors.completionPanel?.suggestionPanelStyle),
                behavior: .init(indentOption: options.insertSpaces ? .spaces(count: options.tabWidth) : .tab),
                layout: .init(contentInsets: insets),
                peripherals: .init(
                    showMinimap: options.showMinimap,
                    invisibleCharactersConfiguration: options.showInvisibles
                        ? InvisibleCharactersConfiguration(showSpaces: true, showTabs: true, showLineEndings: false)
                        : .empty)),
            state: $state,
            coordinators: [coordinator],
            completionDelegate: suggest == nil ? nil : coordinator,
            jumpToDefinitionDelegate: definitions == nil ? nil : coordinator
        )
        .onAppear {
            coordinator.colors = colors
            coordinator.suggest = suggest
            coordinator.suggestionTriggers = suggestionTriggers
            coordinator.signatureTriggers = signatureTriggers
            coordinator.signatureShown = signatureShown
            coordinator.onSignature = onSignature
            coordinator.onEditsApplied = onEditsApplied
            coordinator.onMenuPick = onMenuPick
            coordinator.onCaretRect = onCaretRect
            coordinator.onLineMarkClick = onLineMarkClick
            coordinator.lineMarkView.marks = lineMarks
            coordinator.onAnchor = onAnchor
            coordinator.onSelection = onSelection
            coordinator.anchorLine = anchorLine
            coordinator.definitions = definitions
            coordinator.onOpenLink = onOpenLink
            coordinator.hover.onHover = onHover
            coordinator.onEdit = onEdit
            coordinator.onCursor = onCursor
            coordinator.onFocusedCaret = onFocusedCaret
            go(to: goToLine)
            take(focus)
            // One turn later, as `go(to:)`: the controller has not loaded its view on first appearance.
            DispatchQueue.main.async {
                coordinator.apply(marks)
                coordinator.apply(edits)
                coordinator.open(menu)
                if let controller = coordinator.controller {
                    coordinator.installLineMarks(controller)
                    coordinator.installLineWash(controller)
                }
                coordinator.reportAnchor()
            }
        }
        .onChange(of: goToLine) { _, line in go(to: line) }
        .onChange(of: focus) { _, focus in take(focus) }
        .onChange(of: marks) { _, marks in coordinator.apply(marks) }
        .onChange(of: suggestionTriggers) { _, triggers in coordinator.suggestionTriggers = triggers }
        .onChange(of: signatureTriggers) { _, triggers in coordinator.signatureTriggers = triggers }
        .onChange(of: signatureShown) { _, shown in coordinator.signatureShown = shown }
        .onChange(of: edits) { _, edits in coordinator.apply(edits) }
        .onChange(of: menu) { _, menu in coordinator.open(menu) }
        .onChange(of: lineMarks) { _, marks in coordinator.lineMarkView.marks = marks }
        .onChange(of: anchorLine) { _, line in
            coordinator.anchorLine = line
            coordinator.reportAnchor()
        }
    }

    /// Through the controller, not `state.cursorPositions`: CodeEdit's state diff compares the new positions
    /// with themselves, so a caret set through state is never applied.
    private func go(to line: Int?) {
        guard let line else { return }
        // One turn later: on first appearance the controller has not loaded its view yet.
        DispatchQueue.main.async {
            coordinator.controller?.setCursorPositions([CursorPosition(line: line, column: 1)], scrollToVisible: true)
            coordinator.flash(line: line)
            onGoToLineHandled()
        }
    }

    /// One turn later, as `go(to:)`: the text view is not in the window yet, and the palette that asked is
    /// still leaving (E1D1 FD8 — the same family as the palette's own focus, E0 FD2).
    private func take(_ focus: Bool) {
        guard focus else { return }
        DispatchQueue.main.async {
            if let textView = coordinator.controller?.textView { textView.window?.makeFirstResponder(textView) }
            onFocusHandled()
        }
    }

    /// Drops the scroll view's opaque background (it paints `textBackgroundColor` even when the theme
    /// background is clear) and reports edits and the caret.
    @MainActor
    final class Coordinator: @preconcurrency TextViewCoordinator {
        var onEdit: () -> Void = {}
        var onCursor: (Int, Int) -> Void = { _, _ in }
        var onFocusedCaret: () -> Void = {}
        var definitions: ((Int) async -> [EditorLink])?
        var onOpenLink: (EditorLink) -> Void = { _ in }
        let hover = HoverTracker()
        var colors: EditorColors?
        var suggest: ((Int) async -> [EditorSuggestion])?
        var suggestionTriggers: Set<String> = []
        /// The server's last offer, and where the word it completes starts.
        var offered: [EditorSuggestion] = []
        var wordStart = 0
        var signatureTriggers: Set<String> = []
        var signatureShown = false
        var onSignature: ((Int, CGRect)?) -> Void = { _ in }
        var onEditsApplied: (Int) -> Void = { _ in }
        var appliedEditsID: Int?
        var onMenuPick: (Int?) -> Void = { _ in }
        var openedMenuID: Int?
        var onCaretRect: (CGRect, CGFloat) -> Void = { _, _ in }
        var onLineMarkClick: (Int, CGRect) -> Void = { _, _ in }
        let lineMarkView = LineMarkView()
        let lineWashView = LineWashView()
        var washObserver: (any NSObjectProtocol)?
        var gutterObserver: (any NSObjectProtocol)?
        var anchorLine: Int?
        var onAnchor: (CGRect?) -> Void = { _ in }
        var onSelection: (NSRange) -> Void = { _ in }
        var anchorObserver: (any NSObjectProtocol)?
        private var lastAnchor: CGRect?
        weak var controller: TextViewController?

        /// `prepareCoordinator` runs before the controller loads its view (`scrollView`, implicitly unwrapped, is
        /// still nil), and `viewDidAppear` does not reliably fire inside a SwiftUI host — so one run-loop turn later.
        func prepareCoordinator(controller: TextViewController) {
            self.controller = controller
            DispatchQueue.main.async { [weak controller, hover] in
                guard let controller, let scrollView = controller.scrollView else { return }
                scrollView.drawsBackground = false
                scrollView.contentView.drawsBackground = false
                hover.attach(to: controller.textView, container: controller.view, scrollView: scrollView)
                self.anchorObserver = NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
                ) { [weak self] _ in MainActor.assumeIsolated { self?.reportAnchor() } }
            }
            lineMarkView.onClick = { [weak self] tag, rect in self?.lineMarkClicked(tag, rect) }
        }

        func textViewDidChangeText(controller: TextViewController) {
            hover.dismiss()
            lineMarkView.needsDisplay = true
            lineWashView.needsDisplay = true
            DispatchQueue.main.async { [weak self] in self?.reportAnchor() }
            onEdit()
        }

        /// Underlines through CodeEditTextView's emphasis manager, replacing the previous set.
        func apply(_ marks: [EditorMark]) {
            guard let textView = controller?.textView, let manager = textView.emphasisManager else { return }
            manager.removeEmphases(for: "forge.marks")
            let length = textView.textStorage.length
            lineWashView.washes = marks.filter(\.isLineWash)
            let emphases = marks.compactMap { mark -> Emphasis? in
                guard !mark.isLineWash, mark.range.location < length else { return nil }
                let range = NSRange(location: mark.range.location, length: max(1, min(mark.range.length, length - mark.range.location)))
                return Emphasis(range: range, style: mark.isWash ? .outline(color: mark.color, fill: true) : .underline(color: mark.color))
            }
            if !emphases.isEmpty { manager.addEmphases(emphases, for: "forge.marks") }
        }

        func textViewDidChangeSelection(controller: TextViewController, newPositions: [CursorPosition]) {
            clampSelection(controller)
            if let first = newPositions.first {
                onCursor(first.start.line, first.start.column)
                onSelection(first.range)
                if let frame = caretFrame(controller, first.range.location) { onCaretRect(frame, lineEnd(controller, first.range.location) ?? frame.maxX) }
            }
            trackSignature(controller, newPositions)
            if let textView = controller.textView, textView.window?.firstResponder === textView { onFocusedCaret() }
        }
    }
}

extension EditorHost.Coordinator: @preconcurrency JumpToDefinitionDelegate {
    func queryLinks(forRange range: NSRange, textView: TextViewController) async -> [JumpToDefinitionLink]? {
        guard let definitions else { return nil }
        hover.dismiss()
        return await definitions(range.location).map {
            JumpToDefinitionLink(
                url: URL(fileURLWithPath: $0.path), targetRange: CursorPosition(line: $0.line, column: 1),
                typeName: $0.label, sourcePreview: $0.preview, documentation: nil)
        }
    }

    /// Every link carries a file, this one included: the caller opens it and moves the caret, one path for all.
    func openLink(link: JumpToDefinitionLink) {
        guard let url = link.url else { return }
        onOpenLink(
            EditorLink(path: url.path, line: link.targetRange.start.line, label: link.label, preview: link.sourcePreview ?? ""))
    }
}

extension EditorHost.Coordinator {
    /// Reports where `anchorLine`'s text is, if it changed (nil when there is no such line or it is out of view).
    func reportAnchor() {
        var rect: CGRect?
        if let line = anchorLine, let controller, line >= 1 {
            let text = controller.textView.textStorage.string as NSString
            var start = 0
            var number = 1
            while number < line, start < text.length {
                start = NSMaxRange(text.lineRange(for: NSRange(location: start, length: 0)))
                number += 1
            }
            if number == line, start <= text.length, let caret = caretFrame(controller, start) {
                let end = lineEnd(controller, start) ?? caret.maxX
                let frame = CGRect(x: caret.minX, y: caret.minY, width: max(1, end - caret.minX), height: caret.height)
                rect = controller.view.bounds.intersects(frame) ? frame : nil
            }
        }
        guard rect != lastAnchor else { return }
        lastAnchor = rect
        onAnchor(rect)
    }
}

