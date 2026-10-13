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
    /// Take keyboard focus, and how to say it was done.
    var focus = false
    var onFocusHandled: () -> Void = {}
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
    var anchorLine: Int?
    var onAnchor: (CGRect?) -> Void = { _ in }
    let onEdit: () -> Void
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    /// The settings, in the theme's code face.
    private var codeOptions: EditorOptions {
        var options = options
        options.fontFamily = skin.type.monoFamily
        return options
    }

    var body: some View {
        ForgeCodeEditor(
            storage: document.storage, language: document.language,
            colors: EditorPalette.colors(tokens: theme, palette: palette, skin: skin), options: codeOptions,
            insets: NSEdgeInsets(top: skin.size.s4, left: 0, bottom: skin.size.s12, right: 0),
            onEdit: onEdit,
            onCursor: { line, column in document.cursor = (line, column) },
            goToLine: goToLine, onGoToLineHandled: onGoToLineHandled, focus: focus, onFocusHandled: onFocusHandled,
            onFocusedCaret: onCaret, marks: marks,
            definitions: definitions, onOpenLink: onOpenLink, onHover: onHover, suggest: suggest,
            suggestionTriggers: suggestionTriggers, signatureTriggers: signatureTriggers, signatureShown: signatureShown,
            onSignature: onSignature, edits: edits, onEditsApplied: onEditsApplied, menu: menu, onMenuPick: onMenuPick,
            onCaretRect: onCaretRect, lineMarks: lineMarks, onLineMarkClick: onLineMarkClick, anchorLine: anchorLine,
            onAnchor: onAnchor, onSelection: { range in document.selection = range })
    }
}

/// Syntax colours. Neon and Liquid Glass take the mockups' palettes (forge.css `--syn-*`: Neon's bright kit hues,
/// Glass's softer Xcode-dark set); any other theme its terminal palette — the same ANSI colours Rune uses, so code
/// reads the same in the editor and the terminal. A host that publishes no palette falls back to the theme accents.
enum EditorPalette {
    /// keyword, type, string, number, call, attribute — and the comment's alpha.
    struct Mockup {
        let keyword, type, string, number, call, attribute: String
        let commentAlpha: Double
    }

    static let neon = Mockup(
        keyword: "c084fc", type: "22d3ee", string: "fbbf24", number: "f472b6", call: "60a5fa", attribute: "34d399",
        commentAlpha: 0.38)
    static let glass = Mockup(
        keyword: "ff7ab2", type: "dabaff", string: "ff8170", number: "d9c97c", call: "6bdfff", attribute: "b281eb",
        commentAlpha: 0.42)

    /// The mockup palette for the theme, if it is one of the two the mockups draw.
    static func mockup(themeID: String, glass: Bool) -> Mockup? {
        glass ? Self.glass : themeID.lowercased().hasPrefix("neon") ? neon : nil
    }

    static func colors(tokens: HostThemeTokens, palette: HostTerminalPalette?, skin: AinkradSkin) -> EditorColors {
        let fg = NSColor(tokens.foreground)
        if let mockup = mockup(themeID: tokens.themeID, glass: skin.usesNativeGlass) {
            let hue = { (hex: String) in color(hex: hex) ?? fg }
            return EditorColors(
                text: fg,
                insertionPoint: NSColor(tokens.accentSecondary),
                // `--sel` and `--line-hl`.
                selection: skin.usesNativeGlass ? hue("648cff").withAlphaComponent(0.32) : NSColor(tokens.accentPrimary).withAlphaComponent(0.35),
                lineHighlight: skin.usesNativeGlass ? fg.withAlphaComponent(0.05) : NSColor(tokens.accentSecondary).withAlphaComponent(0.06),
                keywords: hue(mockup.keyword), commands: hue(mockup.call), types: hue(mockup.type),
                attributes: hue(mockup.attribute), variables: fg, values: hue(mockup.type), numbers: hue(mockup.number),
                strings: hue(mockup.string), comments: fg.withAlphaComponent(mockup.commentAlpha),
                completionPanel: panel(tokens: tokens, skin: skin))
        }
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
            comments: fg.withAlphaComponent(0.4),
            completionPanel: panel(tokens: tokens, skin: skin))
    }

    /// The completion panel in the kit's panel finish (`ainkradPanel`'s fill and corner) with a list row's
    /// selected wash (the accent at o16) — not CodeEdit's grey (FD5).
    static func panel(tokens: HostThemeTokens, skin: AinkradSkin) -> EditorPanelStyle {
        EditorPanelStyle(
            background: NSColor(tokens.background.opacity(skin.material.panelOpacity)),
            selection: NSColor(tokens.accentPrimary.opacity(skin.opacity.o16)),
            cornerRadius: AinkradRadius.panel)
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
