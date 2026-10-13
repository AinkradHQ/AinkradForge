import AppKit
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
            // `.peek`: 640 pt — the head (`● Changed · lines 18–21 against HEAD … 1 of 3 ↑↓`), the old lines on a
            // red wash, then three `.btn`s.
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: skin.size.s8) {
                    Text("●").foregroundStyle(color(hunk))
                    Text(title(hunk)).foregroundStyle(skin.color(skin.text.muted))
                    Spacer(minLength: skin.size.s8)
                    HStack(spacing: skin.size.s4) {
                        Text("\(peek.hunk + 1) of \(hunks.count)").monospacedDigit()
                        StepGlyph(glyph: "↑", tooltip: "Previous Change") { model.stepPeek(by: -1) }
                        StepGlyph(glyph: "↓", tooltip: "Next Change") { model.stepPeek(by: 1) }
                    }
                    .foregroundStyle(skin.color(skin.text.faint))
                }
                .font(skin.font(AinkradFontToken(sizeKey: "t11")))
                .padding(.top, skin.size.s8)
                .padding(.horizontal, skin.size.s12)
                .padding(.bottom, skin.size.s4)
                let old = hunk.lines.filter { $0.kind == .deletion }
                if !old.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(old.prefix(12).enumerated()), id: \.offset) { _, line in
                            Text(line.text.isEmpty ? " " : line.text)
                                .font(skin.font(AinkradFontToken(size: 11.5, mono: "family")))
                                .foregroundStyle(theme.foreground)
                                .lineLimit(1)
                                .padding(.vertical, skin.size.s1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, skin.size.s6)
                                .background(status.danger.opacity(skin.opacity.o14))
                        }
                    }
                    .padding(.vertical, skin.size.s4)
                    .padding(.horizontal, skin.size.s12)
                }
                HStack(spacing: skin.size.s8) {
                    AinkradButton(title: "Revert Change", style: .secondary) { model.revertPeek() }.secondaryAccent().fixedSize()
                    AinkradButton(title: "Stage Change", style: .secondary) { model.stagePeek() }.secondaryAccent().fixedSize()
                    AinkradButton(title: "Open in Git Mage", style: .secondary) { model.openGitMage() }.secondaryAccent().fixedSize()
                }
                .padding(.top, skin.size.s6)
                .padding(.horizontal, skin.size.s12)
                .padding(.bottom, skin.size.s10)
            }
            .frame(width: skin.size.s640)
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

/// Blame at the end of the caret's line, quiet; on hover, the commit's card. Fills the editor, to know its width.
struct BlameView: View {
    let model: ForgeModel
    let note: BlameNote
    /// Where the note starts: just past the line's end.
    let leading: CGFloat
    @State private var isHovered: Bool
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    /// `isHovered` opens the card from the start, for snapshots.
    init(model: ForgeModel, note: BlameNote, leading: CGFloat, isHovered: Bool = false) {
        self.model = model
        self.note = note
        self.leading = leading
        _isHovered = State(initialValue: isHovered)
    }

    var body: some View {
        GeometryReader { editor in
            // The card is wider than the note: near the editor's right edge it slides left to stay inside, while the
            // note stays put (E1D1 FD17).
            let overflow = leading + skin.size.s380 + skin.size.s16 - editor.size.width
            let shift = isHovered && note.card != nil ? max(0, min(leading, overflow)) : 0
            content(shift: shift).padding(.leading, leading - shift)
        }
    }

    private func content(shift: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: skin.size.s6) {
            Text(label)
                .font(skin.font(AinkradFontToken(sizeKey: "t11")))
                .italic()
                .foregroundStyle(skin.color(skin.text.faint))
                .lineLimit(1)
                .padding(.leading, shift)
            if isHovered, let card = note.card {
                // `.commit`: 380 pt — avatar, author and time; the subject; hash and stat; two `.btn`s.
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: skin.size.s8) {
                        Circle()
                            .fill(LinearGradient(colors: [theme.accentPrimary, theme.accentSecondary], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: skin.size.s20, height: skin.size.s20)
                        Text(card.author).font(skin.font(AinkradFontToken(sizeKey: "t12", weight: "bold")))
                        Spacer(minLength: skin.size.s12)
                        Text(card.when).font(skin.font(AinkradFontToken(sizeKey: "t11"))).foregroundStyle(skin.color(skin.text.faint))
                    }
                    .padding(.top, skin.size.s10)
                    .padding(.bottom, skin.size.s2)
                    Text(card.subject).font(skin.font(AinkradFontToken(sizeKey: "t12"))).foregroundStyle(theme.foreground)
                        .padding(.vertical, skin.size.s6)
                    Text("\(card.hash) · \(card.stat)")
                        .font(skin.font(AinkradFontToken(sizeKey: "t10_5", mono: "family")))
                        .foregroundStyle(skin.color(skin.text.faint))
                        .padding(.bottom, skin.size.s6)
                    HStack(spacing: skin.size.s8) {
                        AinkradButton(title: "Open in Git Mage", style: .secondary) {
                            model.openGitMage(sha: note.blame.hash, title: card.subject)
                        }
                        .secondaryAccent()
                        .fixedSize()
                        AinkradButton(title: "Copy Hash", style: .secondary) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(note.blame.hash, forType: .string)
                        }
                        .secondaryAccent()
                        .fixedSize()
                    }
                    .padding(.top, skin.size.s4)
                    .padding(.bottom, skin.size.s10)
                }
                .padding(.horizontal, skin.size.s12)
                .frame(width: skin.size.s380, alignment: .leading)
                .ainkradPanel()
            }
        }
        // The note and its card together: the pointer can move from one to the other's buttons.
        .onHover { hovering in
            isHovered = hovering
            if hovering, let workspace = model.workspace { model.git.loadCard(git: Git(directory: workspace.root)) }
        }
    }

    private var label: String {
        let blame = note.blame
        if blame.isUncommitted { return "You · not committed yet" }
        let when = blame.time.formatted(.relative(presentation: .named))
        return "\(blame.author) · \(when) · \(blame.summary)"
    }
}

/// The peek's `↑` / `↓`: bare glyphs that step through the file's changes.
private struct StepGlyph: View {
    let glyph: String
    let tooltip: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { Text(glyph) }  // design-lint: allow raw-control the mockup's bare ↑↓ stepper
            .buttonStyle(.plain)
            .help(tooltip)
    }
}
