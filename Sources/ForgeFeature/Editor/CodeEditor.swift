import AinkradAppKit
import AppKit
import ForgeEditor
import SwiftUI

/// The editor for one document, coloured from the host theme.
struct CodeEditor: View {
    let document: EditorDocument
    /// `host.theme.terminalPalette`.
    let palette: HostTerminalPalette?
    var options = EditorOptions()
    /// A line to jump to, and how to say it was done.
    var goToLine: Int?
    var onGoToLineHandled: () -> Void = {}
    /// The caret moved while this editor has focus (a click or a key here — not a load).
    var onCaret: () -> Void = {}
    /// Diagnostics to underline.
    var marks: [EditorMark] = []
    var definitions: ((Int) async -> [EditorLink])?
    var onOpenLink: (EditorLink) -> Void = { _ in }
    var onHover: ((Int, CGRect)?) -> Void = { _ in }
    var suggest: ((Int) async -> [EditorSuggestion])?
    var suggestionTriggers: Set<String> = []
    var signatureTriggers: Set<String> = []
    var signatureShown = false
    var onSignature: ((Int, CGRect)?) -> Void = { _ in }
    var edits: EditorEdits?
    var onEditsApplied: (Int) -> Void = { _ in }
    var menu: EditorMenu?
    var onMenuPick: (Int?) -> Void = { _ in }
    var onCaretRect: (CGRect, CGFloat) -> Void = { _, _ in }
    var lineMarks: [EditorLineMark] = []
    var onLineMarkClick: (Int, CGRect) -> Void = { _, _ in }
    let onEdit: () -> Void
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        ForgeCodeEditor(
            storage: document.storage, language: document.language,
            colors: EditorPalette.colors(tokens: theme, palette: palette), options: options,
            insets: NSEdgeInsets(top: skin.size.s4, left: 0, bottom: skin.size.s12, right: 0),
            onEdit: onEdit,
            onCursor: { line, column in document.cursor = (line, column) },
            goToLine: goToLine, onGoToLineHandled: onGoToLineHandled, onFocusedCaret: onCaret, marks: marks,
            definitions: definitions, onOpenLink: onOpenLink, onHover: onHover, suggest: suggest,
            suggestionTriggers: suggestionTriggers, signatureTriggers: signatureTriggers, signatureShown: signatureShown,
            onSignature: onSignature, edits: edits, onEditsApplied: onEditsApplied, menu: menu, onMenuPick: onMenuPick,
            onCaretRect: onCaretRect, lineMarks: lineMarks, onLineMarkClick: onLineMarkClick)
    }
}

/// Syntax colours from the active theme's terminal palette — the same ANSI colours Rune uses, so code reads
/// the same in the editor and the terminal. A host that publishes no palette falls back to the theme accents.
enum EditorPalette {
    static func colors(tokens: HostThemeTokens, palette: HostTerminalPalette?) -> EditorColors {
        let fg = NSColor(tokens.foreground)
        func ansi(_ index: Int, _ fallback: Color) -> NSColor {
            guard let palette, palette.ansi.indices.contains(index), let color = color(hex: palette.ansi[index]) else {
                return NSColor(fallback)
            }
            return color
        }
        return EditorColors(
            text: fg,
            insertionPoint: NSColor(tokens.accentSecondary),
            selection: NSColor(tokens.accentPrimary).withAlphaComponent(0.35),
            lineHighlight: fg.withAlphaComponent(0.05),
            keywords: ansi(5, tokens.accentPrimary),
            commands: ansi(4, tokens.accentPrimary),
            types: ansi(6, tokens.accentSecondary),
            attributes: ansi(2, tokens.accentTertiary),
            variables: fg,
            values: ansi(14, tokens.accentSecondary),
            numbers: ansi(13, tokens.accentPrimary),
            strings: ansi(3, tokens.accentTertiary),
            comments: fg.withAlphaComponent(0.4))
    }

    /// `RRGGBB` (optionally `#`-prefixed) → sRGB colour.
    static func color(hex: String) -> NSColor? {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return NSColor(  // design-lint: allow raw-color decodes host.theme.terminalPalette hex (theme data)
            srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}
