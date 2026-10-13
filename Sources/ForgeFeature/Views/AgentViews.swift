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

/// Every change made from outside Forge since the last review, file by file; each change ticked (kept) —
/// untick to undo it. Done undoes the unticked ones and clears the review.
struct ReviewAllPane: View {
    let model: ForgeModel
    /// Files whose diff is showing; until the first click, only the first file's (mockup 16).
    @State private var shown: Set<String>?
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        // Once Grimoire has announced a turn, the review groups by turn (screen 18).
        if model.reviewsByTurn { TurnReviewPane(model: model) } else { list }
    }

    @ViewBuilder private var list: some View {
        let entries = model.reviewEntries
        let open = shown ?? Set(entries.first.map { [$0.path] } ?? [])
        VStack(alignment: .leading, spacing: skin.size.s12) {
            HStack(spacing: skin.size.s10) {
                VStack(alignment: .leading, spacing: skin.size.s2) {
                    Text("Changes outside Forge").font(skin.font(AinkradFontToken(sizeKey: "t14", weight: "semibold")))
                    Text(subtitle(entries))
                        .font(skin.font(AinkradFontToken(sizeKey: "t11", monospacedDigits: true)))
                        .foregroundStyle(skin.color(skin.text.muted))
                        .lineLimit(1)
                }
                Spacer(minLength: skin.size.s8)
                AinkradButton(title: "Undo All", style: .secondary) { model.finishReview(undoAll: true) }.secondaryAccent().fixedSize()
                AinkradButton(title: "Keep All", style: .secondary) { model.keepAllOutside() }.secondaryAccent().fixedSize()
                AinkradButton(title: "Done", style: .primary) { model.finishReview() }.fixedSize()
            }
            if entries.isEmpty {
                AinkradEmptyState(icon: "checkmark.circle", title: "Nothing to review", message: "No file has changed from outside Forge since the last review.")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: skin.size.s12) {
                    ForEach(entries, id: \.path) { entry in
                        let counts = ReviewFileRow.counts(entry.diff)
                        ReviewFileRow(
                            path: entry.path, note: entry.isNew ? "new file" : entry.isDeleted ? "deleted" : nil,
                            added: counts.added, removed: counts.removed
                        ) {
                            var next = open
                            if next.remove(entry.path) == nil { next.insert(entry.path) }
                            shown = next
                        }
                        if open.contains(entry.path) {
                            AinkradDiffReview(
                                fileDiff: entry.diff,
                                rejectedHunkIDs: Binding(
                                    get: { model.agent.unticked[entry.path] ?? [] },
                                    set: { model.agent.unticked[entry.path] = $0 })
                            )
                            .reviewStyle()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .reviewSurface(skin, theme)
    }

    /// "5 files · 9 changes · since 10:42 · 1 change unticked — Done undoes it".
    private func subtitle(_ entries: [(path: String, diff: AinkradFileDiff, isNew: Bool, isDeleted: Bool)]) -> String {
        let changes = entries.reduce(0) { $0 + $1.diff.hunks.count }
        let unticked = model.agent.unticked.values.reduce(0) { $0 + $1.count }
        let since = (model.agent.files.values.map(\.since) + model.agent.others.values.map(\.since)).min()
        return "\(entries.count) file\(entries.count == 1 ? "" : "s") · \(changes) change\(changes == 1 ? "" : "s")"
            + (since.map { " · since " + $0.formatted(date: .omitted, time: .shortened) } ?? "")
            + (unticked > 0 ? " · \(unticked) change\(unticked == 1 ? "" : "s") unticked — Done undoes \(unticked == 1 ? "it" : "them")" : "")
    }
}

/// "✦ 5 changed outside" — in the status bar and atop the Changes tab; opens Review All.
struct OutsideChangesButton: View {
    let model: ForgeModel
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradReduceMotion) private var reduceMotion

    var body: some View {
        let count = model.agent.count
        if count > 0 {
            // A plain button, so Full Keyboard Access reaches it (E1D2 FD40); the palette has Review Changes too.
            Button { model.agent.reviewingAll = true } label: {  // design-lint: allow raw-control keyboard-reachable status item
                label(count)
                    .foregroundStyle(theme.accentSecondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Review changes made outside Forge")
        }
    }

    /// "✦ Claude turn 3 · 4 files + 2 more turns" once turns are announced (the ✦ pulses once per new turn).
    @ViewBuilder
    private func label(_ count: Int) -> some View {
        let turns = model.reviewsByTurn ? model.turnGroups.filter { $0.turn != nil && !$0.kept } : []
        if let newest = turns.first, let turn = newest.turn {
            HStack(spacing: skin.size.s4) {
                Image(systemName: "sparkle").symbolEffect(.pulse, options: .nonRepeating, value: turns.count).symbolEffectsRemoved(reduceMotion)
                Text("\(turn.agent) turn \(turn.turn) · \(newest.files.count == 1 ? "1 file" : "\(newest.files.count) files")")
                if turns.count > 1 {
                    Text("+ \(turns.count - 1) more turn\(turns.count == 2 ? "" : "s")").foregroundStyle(skin.color(skin.text.faint))
                }
            }
        } else {
            Label("\(count) changed outside", systemImage: "sparkle")
        }
    }
}

/// ⌘I's card at the selection: what goes with the request, and what to do. Ask (⌘↵) opens a new Grimoire
/// thread with it.
struct AskAgentCard: View {
    let model: ForgeModel
    let request: AskRequest
    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        let lines = request.lines.count == 1 ? "line \(request.lines.lowerBound)" : "lines \(request.lines.lowerBound)–\(request.lines.upperBound)"
        VStack(alignment: .leading, spacing: skin.size.s6) {
            Text("\((request.path as NSString).lastPathComponent) · \(lines)")
                .font(skin.font(AinkradFontToken(sizeKey: "t11", mono: "system")))
                .foregroundStyle(skin.color(skin.text.faint))
            AinkradComposer(
                text: Binding(get: { model.agent.ask?.prompt ?? "" }, set: { model.agent.ask?.prompt = $0 }),
                placeholder: "What should the agent do?", isEditable: true,
                canSend: !request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, autoFocus: true,
                suggestions: { _ in [] }, onPick: { _, _ in }, onDrop: nil, onSend: { model.sendAsk() },
                chips: { EmptyView() },
                leading: {
                    Label("Grimoire · this workspace", systemImage: "sparkles")
                        .font(skin.font(AinkradFontToken(sizeKey: "t11")))
                        .foregroundStyle(skin.color(skin.text.muted))
                },
                trailing: { EmptyView() })
            Text("Ask opens a new Grimoire thread with this — you choose the agent and start it.")
                .font(skin.font(AinkradFontToken(sizeKey: "t10")))
                .foregroundStyle(skin.color(skin.text.faint))
        }
        .frame(width: skin.size.s440)
        .onExitCommand { model.agent.ask = nil }
    }
}
