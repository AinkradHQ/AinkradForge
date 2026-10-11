import AinkradAppKit
import SwiftUI

/// Heads a file changed from outside Forge: how much, how long ago, ‹ › through the changes, Undo / Keep All.
struct ReviewBar: View {
    let model: ForgeModel
    let path: String
    let file: AgentReview.FileChanges
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        let count = file.diff.hunks.count
        HStack(spacing: skin.size.s8) {
            Image(systemName: "sparkle").foregroundStyle(theme.accentSecondary)
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                Text("Changed outside Forge · \(count) change\(count == 1 ? "" : "s") · \(file.since.formatted(.relative(presentation: .named)))")
                    .foregroundStyle(skin.color(skin.text.muted))
            }
            Spacer(minLength: skin.size.s8)
            AinkradIconButton(systemName: "chevron.left", size: skin.size.s18, tooltip: "Previous Change") { model.stepChange(path, by: -1) }
            Text("\((model.agent.current[path] ?? 0) + 1) of \(count)")
                .font(skin.font(AinkradFontToken(sizeKey: "t11", monospacedDigits: true)))
                .foregroundStyle(skin.color(skin.text.faint))
            AinkradIconButton(systemName: "chevron.right", size: skin.size.s18, tooltip: "Next Change") { model.stepChange(path, by: 1) }
            AinkradButton(title: "Undo All", style: .secondary) { model.undoAllChanges(path) }.fixedSize()
            AinkradButton(title: "Keep All", style: .primary) { model.keepAllChanges(path) }.fixedSize()
        }
        .font(skin.font(AinkradFontToken(sizeKey: "t12")))
        .padding(.vertical, skin.size.s4)
        .padding(.horizontal, skin.size.s10)
        .background(Capsule().fill(theme.accentSecondary.opacity(skin.opacity.o08)))
    }
}

/// The current change's actions, at the end of its first line: Keep, Undo, and what it was.
struct ChangeChip: View {
    let model: ForgeModel
    let path: String
    let hunk: Int
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradStatusColors) private var status

    var body: some View {
        VStack(alignment: .leading, spacing: skin.size.s6) {
            HStack(spacing: skin.size.s2) {
                chipButton("checkmark", "Keep", status.success, "⌘↵") { model.keepChange(path, hunk: hunk) }
                chipButton("arrow.uturn.backward", "Undo", status.danger, "⌘⌫") { model.undoChange(path, hunk: hunk) }
                chipButton(model.agent.showingWas ? "chevron.up" : "chevron.down", "Was", skin.color(skin.text.muted), nil) {
                    model.agent.showingWas.toggle()
                }
            }
            .padding(skin.size.s2)
            .background(Capsule().fill(theme.surface.opacity(skin.opacity.o90)))
            if model.agent.showingWas, let change = model.agent.files[path]?.diff.hunks[safe: hunk] {
                let old = Self.dedented(change.lines.filter { $0.kind == .deletion }.map(\.text))
                VStack(alignment: .leading, spacing: 0) {
                    if old.isEmpty {
                        Text("Nothing — these lines are new.")
                            .font(skin.font(AinkradFontToken(sizeKey: "t11")))
                            .foregroundStyle(skin.color(skin.text.faint))
                    }
                    ForEach(Array(old.prefix(12).enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line)
                            .font(skin.font(AinkradFontToken(sizeKey: "t11", mono: "system")))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, skin.size.s6)
                            .background(status.danger.opacity(skin.opacity.o16))
                    }
                }
                .padding(skin.size.s8)
                .frame(width: skin.size.s420)
                .ainkradPanel()
            }
        }
    }

    /// The lines without the indentation they share.
    static func dedented(_ lines: [String]) -> [String] {
        let indent = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
        return lines.map { String($0.dropFirst(min(indent, $0.prefix { $0 == " " || $0 == "\t" }.count))) }
    }

    private func chipButton(_ symbol: String, _ title: String, _ tint: Color, _ keys: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {  // design-lint: allow raw-control compact chip action (kit has no pill segment button)
            Label(keys.map { "\(title) \($0)" } ?? title, systemImage: symbol)
                .font(skin.font(AinkradFontToken(sizeKey: "t11")))
                .foregroundStyle(tint)
                .padding(.vertical, skin.size.s2)
                .padding(.horizontal, skin.size.s8)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(keys.map { "\(title) (\($0))" } ?? title)
    }
}
