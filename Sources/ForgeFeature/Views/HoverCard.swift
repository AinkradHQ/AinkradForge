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

    var body: some View {
        VStack(alignment: .leading, spacing: skin.size.s8) {
            ForEach(info.issues) { issue in
                HStack(alignment: .firstTextBaseline, spacing: skin.size.s6) {
                    Image(systemName: IssueStyle.symbol(issue.severity))
                        .foregroundStyle(IssueStyle.color(issue.severity, status: status, theme: theme))
                    Text(issue.message)
                        .foregroundStyle(theme.foreground)
                }
                .font(skin.font(AinkradFontToken(sizeKey: "t12")))
            }
            ForEach(Array(Self.blocks(info.markdown ?? "").enumerated()), id: \.offset) { _, block in
                switch block {
                case .code(let code):
                    Text(code)
                        .font(skin.font(AinkradFontToken(sizeKey: "t12", mono: "system")))
                        .foregroundStyle(theme.foreground)
                case .prose(let prose):
                    Text(prose)
                        .font(skin.font(AinkradFontToken(sizeKey: "t12")))
                        .foregroundStyle(skin.color(skin.text.muted))
                        .lineLimit(14)
                }
            }
            Text("\(info.server) · ⌘-click to jump")
                .font(skin.font(AinkradFontToken(sizeKey: "t10")))
                .foregroundStyle(skin.color(skin.text.faint))
        }
        .frame(maxWidth: skin.size.s400, alignment: .leading)
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

/// The signature of the call being typed, its active parameter bold and underlined.
struct SignatureCard: View {
    let hint: SignatureHint
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        Text(label)
            .font(skin.font(AinkradFontToken(sizeKey: "t12", mono: "system")))
            .lineLimit(2)
            .frame(maxWidth: skin.size.s400, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var label: AttributedString {
        var text = AttributedString(hint.label)
        text.foregroundColor = skin.color(skin.text.muted)
        if let active = hint.activeParameter, let range = Range(active, in: hint.label),
            let start = AttributedString.Index(range.lowerBound, within: text),
            let end = AttributedString.Index(range.upperBound, within: text)
        {
            text[start..<end].foregroundColor = theme.foreground
            text[start..<end].inlinePresentationIntent = .stronglyEmphasized
            text[start..<end].underlineStyle = .single
        }
        return text
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
    @ViewBuilder let card: Card
    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        GeometryReader { geo in
            let gap = skin.size.s4
            let roomBelow = geo.size.height - rect.maxY - gap
            let above = prefersAbove ? rect.minY > skin.size.s44 || roomBelow < skin.size.s44 : roomBelow < skin.size.s160
            card
                .padding(skin.size.s10)
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

