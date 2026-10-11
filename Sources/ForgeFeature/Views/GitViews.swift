import AinkradAppKit
import SwiftUI

/// The peek at a change: its old lines, Revert Change / Stage Change / Open in Git Mage, ↑↓ through the file.
struct GitPeekCard: View {
    let model: ForgeModel
    let peek: GitPeek
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradStatusColors) private var status

    var body: some View {
        let hunks = model.git.hunks[peek.path] ?? []
        if let hunk = hunks[safe: peek.hunk] {
            VStack(alignment: .leading, spacing: skin.size.s8) {
                HStack(spacing: skin.size.s6) {
                    Circle().fill(color(hunk)).frame(width: skin.size.s7, height: skin.size.s7)
                    Text(title(hunk))
                        .font(skin.font(AinkradFontToken(sizeKey: "t11")))
                        .foregroundStyle(skin.color(skin.text.muted))
                    Spacer(minLength: skin.size.s8)
                    Text("\(peek.hunk + 1) of \(hunks.count)")
                        .font(skin.font(AinkradFontToken(sizeKey: "t11", monospacedDigits: true)))
                        .foregroundStyle(skin.color(skin.text.faint))
                    AinkradIconButton(systemName: "chevron.up", size: skin.size.s18, tooltip: "Previous Change") { model.stepPeek(by: -1) }
                    AinkradIconButton(systemName: "chevron.down", size: skin.size.s18, tooltip: "Next Change") { model.stepPeek(by: 1) }
                }
                let old = hunk.lines.filter { $0.kind == .deletion }
                if !old.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(old.prefix(12).enumerated()), id: \.offset) { _, line in
                            Text(line.text.isEmpty ? " " : line.text)
                                .font(skin.font(AinkradFontToken(sizeKey: "t11", mono: "system")))
                                .foregroundStyle(theme.foreground)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, skin.size.s6)
                                .background(status.danger.opacity(skin.opacity.o16))
                        }
                    }
                }
                HStack(spacing: skin.size.s8) {
                    AinkradButton(title: "Revert Change", style: .secondary) { model.revertPeek() }.fixedSize()
                    AinkradButton(title: "Stage Change", style: .secondary) { model.stagePeek() }.fixedSize()
                    AinkradButton(title: "Open in Git Mage", style: .ghost) { model.openGitMage() }.fixedSize()
                }
            }
            .frame(width: skin.size.s520)
        }
    }

    private func color(_ hunk: AinkradDiffHunk) -> Color {
        hunk.newCount == 0 ? status.danger : hunk.oldCount == 0 ? status.success : status.warning
    }

    private func title(_ hunk: AinkradDiffHunk) -> String {
        if hunk.newCount == 0 { return "Removed · \(hunk.oldCount) line\(hunk.oldCount == 1 ? "" : "s") against HEAD" }
        let lines = hunk.newCount == 1 ? "line \(hunk.newStart)" : "lines \(hunk.newStart)–\(hunk.newStart + hunk.newCount - 1)"
        return "\(hunk.oldCount == 0 ? "Added" : "Changed") · \(lines) against HEAD"
    }
}

/// Blame at the end of the caret's line, quiet; on hover, the commit's card.
struct BlameView: View {
    let model: ForgeModel
    let note: BlameNote
    @State private var isHovered = false
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: skin.size.s6) {
            Text(label)
                .font(skin.font(AinkradFontToken(sizeKey: "t11")))
                .italic()
                .foregroundStyle(skin.color(skin.text.faint))
                .lineLimit(1)
                .onHover { hovering in
                    isHovered = hovering
                    if hovering, let workspace = model.workspace { model.git.loadCard(git: Git(directory: workspace.root)) }
                }
            if isHovered, let card = note.card {
                VStack(alignment: .leading, spacing: skin.size.s4) {
                    HStack {
                        Text(card.author).font(skin.font(AinkradFontToken(sizeKey: "t12", weight: "semibold")))
                        Spacer(minLength: skin.size.s12)
                        Text(card.when).font(skin.font(AinkradFontToken(sizeKey: "t11"))).foregroundStyle(skin.color(skin.text.faint))
                    }
                    Text(card.subject).font(skin.font(AinkradFontToken(sizeKey: "t12"))).foregroundStyle(theme.foreground)
                    Text("\(card.hash) · \(card.stat)")
                        .font(skin.font(AinkradFontToken(sizeKey: "t10", mono: "system")))
                        .foregroundStyle(skin.color(skin.text.faint))
                }
                .padding(skin.size.s10)
                .frame(width: skin.size.s360, alignment: .leading)
                .ainkradPanel()
            }
        }
    }

    private var label: String {
        let blame = note.blame
        if blame.isUncommitted { return "You · not committed yet" }
        let when = blame.time.formatted(.relative(presentation: .named))
        return "\(blame.author) · \(when) · \(blame.summary)"
    }
}
