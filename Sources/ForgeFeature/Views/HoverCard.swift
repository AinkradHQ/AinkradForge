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
        .textSelection(.enabled)
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
