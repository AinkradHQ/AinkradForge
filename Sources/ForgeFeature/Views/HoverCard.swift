import AinkradAppKit
import ForgeLanguage
import SwiftUI

/// The hover card: the issues under the pointer, then the symbol's signature and documentation (the server's
/// Markdown: fenced code in the editor's face, prose rendered inline).
struct HoverCard: View {
    let info: HoverInfo
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradStatusColors) private var status

    /// `.pop`: the issue (`.msg`), the signature syntax-coloured (`.sig`), the documentation (`.doc`), the source
    /// line (`.src`) — 420 pt, each part inset 12.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(info.issues) { issue in
                HStack(alignment: .firstTextBaseline, spacing: skin.size.s8) {
                    Text(IssueStyle.glyph(issue.severity))
                        .foregroundStyle(IssueStyle.color(issue.severity, status: status, theme: theme))
                    Text(issue.message)
                        .foregroundStyle(theme.foreground)
                }
                .font(skin.font(AinkradFontToken(sizeKey: "t12")))
                .padding(.vertical, skin.size.s8)
            }
            ForEach(Array(Self.blocks(info.markdown ?? "").enumerated()), id: \.offset) { _, block in
                switch block {
                case .code(let code):
                    Text(CodeTint.attributed(code, skin: skin, theme: theme))
                        .font(skin.font(AinkradFontToken(sizeKey: "t12", mono: "family")))
                        .padding(.top, skin.size.s10)
                        .padding(.bottom, skin.size.s6)
                case .prose(let prose):
                    Text(prose)
                        .font(skin.font(AinkradFontToken(sizeKey: "t12")))
                        .foregroundStyle(skin.color(skin.text.muted))
                        .lineSpacing(skin.size.s4)
                        .lineLimit(14)
                        .padding(.top, skin.size.s4)
                        .padding(.bottom, skin.size.s10)
                }
            }
            Text("\(info.server) · ⌘-click to jump")
                .font(skin.font(AinkradFontToken(sizeKey: "t10_5")))
                .foregroundStyle(skin.color(skin.text.faint))
                .padding(.bottom, skin.size.s10)
        }
        .padding(.horizontal, skin.size.s12)
        .frame(maxWidth: skin.size.s420, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    enum Block: Equatable {
        case code(String)
        case prose(AttributedString)
    }

    /// Fenced code blocks apart from the prose between them; empty parts dropped.
    nonisolated static func blocks(_ markdown: String) -> [Block] {
        markdown.components(separatedBy: "```").enumerated().compactMap { index, part in
            if index.isMultiple(of: 2) {
                let prose = part.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !prose.isEmpty else { return nil }
                let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                return .prose((try? AttributedString(markdown: prose, options: options)) ?? AttributedString(prose))
            }
            // The fence's first line names the language.
            let code = part.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return code.isEmpty ? nil : .code(code)
        }
    }
}

/// `.sighelp`: the signature of the call being typed on one slim line, its active parameter cyan and underlined.
struct SignatureCard: View {
    let hint: SignatureHint
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        Text(label)
            .font(skin.font(AinkradFontToken(size: 11.5, mono: "family")))
            .lineLimit(2)
            // As wide as the signature (up to 420), not a fixed-width panel.
            .frame(maxWidth: skin.size.s420 - skin.size.s20, alignment: .leading)
            .fixedSize()
            .padding(.vertical, skin.size.s6)
            .padding(.horizontal, skin.size.s10)
    }

    private var label: AttributedString {
        var text = AttributedString(hint.label)
        text.foregroundColor = theme.foreground
        if let active = hint.activeParameter, let range = Range(active, in: hint.label),
            let start = AttributedString.Index(range.lowerBound, within: text),
            let end = AttributedString.Index(range.upperBound, within: text)
        {
            text[start..<end].foregroundColor = theme.accentSecondary
            text[start..<end].underlineStyle = .single
        }
        return text
    }
}

/// A line of code in the mockups' syntax hues (keywords, types, strings, numbers) — for a hover's signature.
/// A token pass, not a parser: enough for one declaration.
enum CodeTint {
    static let keywords: Set<String> = [
        "struct", "class", "enum", "protocol", "extension", "actor", "func", "var", "let", "init", "case", "some", "any",
        "static", "private", "public", "internal", "fileprivate", "final", "mutating", "throws", "async", "await", "return",
        "inout", "where", "import", "typealias", "associatedtype", "subscript", "nonisolated", "true", "false", "nil", "self",
    ]

    @MainActor static func attributed(_ code: String, skin: AinkradSkin, theme: HostThemeTokens) -> AttributedString {
        let mockup = EditorPalette.mockup(themeID: theme.themeID, glass: skin.usesNativeGlass)
        let keyword = mockup.map { ForgeStyle.hue($0.keyword) } ?? theme.accentPrimary
        let type = mockup.map { ForgeStyle.hue($0.type) } ?? theme.accentSecondary
        let string = mockup.map { ForgeStyle.hue($0.string) } ?? theme.accentTertiary
        let number = mockup.map { ForgeStyle.hue($0.number) } ?? theme.accentPrimary
        var out = AttributedString()
        for token in tokens(code) {
            var piece = AttributedString(token)
            let first = token.first
            if token.hasPrefix("\"") {
                piece.foregroundColor = string
            } else if keywords.contains(token) || token.hasPrefix("@") {
                piece.foregroundColor = keyword
            } else if let first, first.isUppercase {
                piece.foregroundColor = type
            } else if let first, first.isNumber {
                piece.foregroundColor = number
            } else {
                piece.foregroundColor = theme.foreground
            }
            out += piece
        }
        return out
    }

    /// Words (`@`-prefixed too), string literals, and every other run of characters as is.
    nonisolated static func tokens(_ code: String) -> [String] {
        var tokens: [String] = []
        var index = code.startIndex
        while index < code.endIndex {
            let char = code[index]
            var end = code.index(after: index)
            if char == "\"" {
                while end < code.endIndex, code[end] != "\"" { end = code.index(after: end) }
                if end < code.endIndex { end = code.index(after: end) }
            } else if char.isLetter || char.isNumber || char == "_" || char == "@" {
                while end < code.endIndex, code[end].isLetter || code[end].isNumber || code[end] == "_" { end = code.index(after: end) }
            } else {
                while end < code.endIndex, !(code[end].isLetter || code[end].isNumber || code[end] == "_" || code[end] == "@" || code[end] == "\"") {
                    end = code.index(after: end)
                }
            }
            tokens.append(String(code[index..<end]))
            index = end
        }
        return tokens
    }
}

/// A card pinned to a rect of the editor — below it, or above (`prefersAbove`, or when there is no room
/// below). Drawn in the editor, not a popover window: a hint never takes the keyboard from the text, nor
/// (unless `interactive`) the pointer, so the editor keeps its hover and clicks.
struct EditorCardLayer<Card: View>: View {
    let rect: CGRect
    let prefersAbove: Bool
    /// The rename field takes clicks and keys; the hover and signature cards take neither.
    var interactive = false
    /// Around the card; nil for the panel's usual 10 pt (the hover and signature cards inset themselves).
    var inset: CGFloat?
    @ViewBuilder let card: Card
    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        GeometryReader { geo in
            let gap = skin.size.s4
            let roomBelow = geo.size.height - rect.maxY - gap
            let above = prefersAbove ? rect.minY > skin.size.s44 || roomBelow < skin.size.s44 : roomBelow < skin.size.s160
            card
                .padding(inset ?? skin.size.s10)
                .ainkradPanel()
                .padding(.leading, max(0, min(rect.minX - skin.size.s10, geo.size.width - skin.size.s420)))
                .frame(
                    width: geo.size.width, height: max(0, above ? rect.minY - gap : roomBelow),
                    alignment: above ? .bottomLeading : .topLeading)
                .offset(y: above ? 0 : rect.maxY + gap)
        }
        .allowsHitTesting(interactive)
    }
}


/// The editor's right edge: where in the file its issues, git changes and outside changes are, each a short mark
/// at its place in the whole file (so a glance shows what is off screen). Not hit-testable.
struct OverviewRuler: View {
    struct Mark: Hashable {
        /// 1-based.
        let line: Int
        let color: Color
    }

    let marks: [Mark]
    let lineCount: Int
    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        GeometryReader { geo in
            let usable = max(1, geo.size.height - skin.size.s4)
            let row = max(skin.size.s3, usable / Double(max(1, lineCount)))
            ForEach(Array(Set(marks)), id: \.self) { mark in
                RoundedRectangle(cornerRadius: skin.size.s1)
                    .fill(mark.color.opacity(skin.opacity.o90))
                    .frame(width: skin.size.s6, height: min(row, skin.size.s8))
                    .offset(x: geo.size.width - skin.size.s8, y: usable * Double(mark.line - 1) / Double(max(1, lineCount)))
            }
        }
        .allowsHitTesting(false)
    }
}
