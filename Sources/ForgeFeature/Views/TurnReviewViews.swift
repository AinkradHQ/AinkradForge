import AinkradAppKit
import SwiftUI

/// The review by Grimoire turn (screen 18): each turn a wash headed "Claude · turn 3 · 4 files" with its request,
/// Keep turn / Undo turn and "Ask about this turn…"; other writers' edits grouped by time window. Newest open,
/// older folded; a kept group dims to one row until Done.
struct TurnReviewPane: View {
    let model: ForgeModel
    /// Groups folded open by hand; until the first fold, the newest pending group is open.
    @State private var opened: Set<String> = []
    @State private var folded = false
    /// The group whose "Ask about this turn…" field is open.
    @State private var asking: String?
    /// An undo that would take newer changes with it, waiting for the person's answer.
    @State private var confirming: TurnLedger.Group?

    init(model: ForgeModel, asking: String? = nil) {
        self.model = model
        _asking = State(initialValue: asking)
    }
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradReduceMotion) private var reduceMotion

    var body: some View {
        let groups = model.turnGroups
        let newest = groups.first { !$0.kept }?.id
        VStack(alignment: .leading, spacing: skin.size.s10) {
            header(groups)
            if groups.isEmpty {
                AinkradEmptyState(icon: "checkmark.circle", title: "Nothing to review", message: "No file has changed from outside Forge since the last review.")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: skin.size.s10) {
                    ForEach(groups) { group in
                        TurnGroupView(
                            model: model, group: group, isOpen: opened.contains(group.id) || (!folded && group.id == newest),
                            asking: $asking, toggle: { toggle(group.id, newest: newest) },
                            undo: { if !model.undo(group: group) { confirming = group } })
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                // A new turn slides in at the top.
                .animation(reduceMotion ? nil : skin.animation(skin.motion.present), value: groups.map(\.id))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(skin.size.s16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: skin.size.s10).fill(theme.surface.opacity(skin.opacity.o45)))
        .padding(.horizontal, skin.size.s14)
        .padding(.top, skin.size.s12)
        .ainkradConfirmDialog(
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            title: "Undo \(confirming?.title ?? "")?",
            message: confirmMessage, confirmTitle: "Undo Both", isDestructive: true
        ) { if let group = confirming { model.undo(group: group, force: true) } }
    }

    private var confirmMessage: String {
        guard let group = confirming else { return "" }
        let newer = model.newerConflicts(group)
        let who = newer.isEmpty ? "A newer change" : newer.joined(separator: ", ")
        return "\(who) edited these lines too. Undoing \(group.turn.map { "turn \($0.turn)" } ?? "these edits") puts those files back to before it — the newer changes to them go too."
    }

    private func toggle(_ id: String, newest: String?) {
        if !folded, let newest { opened.insert(newest) }
        folded = true
        if opened.remove(id) == nil { opened.insert(id) }
    }

    private func header(_ groups: [TurnLedger.Group]) -> some View {
        let turns = groups.filter { $0.turn != nil && !$0.kept }.count
        let files = Set(groups.filter { !$0.kept }.flatMap { $0.files.map(\.path) }).count
        let since = groups.map(\.from).min().map { " · since " + $0.formatted(date: .omitted, time: .shortened) } ?? ""
        let title = VStack(alignment: .leading, spacing: skin.size.s2) {
            Text("Changes outside Forge").font(skin.font(AinkradFontToken(sizeKey: "t14", weight: "semibold")))
            Text("\(turns) turn\(turns == 1 ? "" : "s") · \(files) file\(files == 1 ? "" : "s")\(since) · grouped by agent turn")
                .font(skin.font(AinkradFontToken(sizeKey: "t11", monospacedDigits: true)))
                .foregroundStyle(skin.color(skin.text.muted))
        }
        .lineLimit(1)
        // Narrow (FD38): the buttons wrap under the title, then fold to icons — never off the pane's edge.
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: skin.size.s8) {
                title.fixedSize()
                Spacer(minLength: skin.size.s8)
                headerButtons(icons: false)
            }
            VStack(alignment: .leading, spacing: skin.size.s6) {
                title
                HStack(spacing: skin.size.s8) {
                    Spacer(minLength: 0)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: skin.size.s8) { headerButtons(icons: false) }
                        HStack(spacing: skin.size.s4) { headerButtons(icons: true) }
                    }
                }
            }
        }
    }

    @ViewBuilder private func headerButtons(icons: Bool) -> some View {
        if icons {
            AinkradIconButton(systemName: "arrow.uturn.backward", tooltip: "Undo All") { model.finishReview(undoAll: true) }
            AinkradIconButton(systemName: "checkmark.circle", tooltip: "Keep All") { model.keepAllOutside() }
            AinkradIconButton(systemName: "checkmark", tooltip: "Done") { model.finishTurnReview() }
        } else {
            AinkradButton(title: "Undo All", style: .secondary) { model.finishReview(undoAll: true) }.fixedSize()
            AinkradButton(title: "Keep All", style: .secondary) { model.keepAllOutside() }.fixedSize()
            AinkradButton(title: "Done", style: .primary) { model.finishTurnReview() }.fixedSize()
        }
    }
}

/// One turn (or outside window): a wash, never a box — its header, and when open its files and their changes.
private struct TurnGroupView: View {
    let model: ForgeModel
    let group: TurnLedger.Group
    let isOpen: Bool
    @Binding var asking: String?
    let toggle: () -> Void
    let undo: () -> Void
    @State private var hovering = false
    @State private var question = ""
    @State private var shownFiles: Set<String>?
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradStatusColors) private var status
    @Environment(\.ainkradReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: skin.size.s6) {
            header
            if isOpen, !group.kept {
                VStack(alignment: .leading, spacing: skin.size.s6) {
                    if asking == group.id, let turn = group.turn { askField(turn) }
                    ForEach(group.files, id: \.path) { file in fileRow(file) }
                }
                .padding(.leading, skin.size.s26)
                .padding(.trailing, skin.size.s6)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, skin.size.s6)
        .padding(.top, skin.size.s4)
        .padding(.bottom, isOpen && !group.kept ? skin.size.s8 : skin.size.s4)
        .background(skin.shape(cut: AinkradRadius.md).fill(washColor.opacity(hovering ? skin.opacity.o08 : skin.opacity.o05)))
        .opacity(group.kept ? skin.opacity.o55 : hovering || isOpen ? 1 : skin.opacity.o88)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(motion(skin.motion.durations.d0_18), value: isOpen)
        .animation(motion(skin.motion.durations.d0_18), value: asking)
        .animation(reduceMotion ? nil : skin.animation(skin.motion.hover), value: hovering)
    }

    private var washColor: Color { group.turn == nil ? theme.accentSecondary : theme.accentPrimary }

    private func motion(_ duration: Double) -> Animation? {
        reduceMotion ? nil : skin.animation(AinkradAnimationToken(curve: "easeInOut", duration: duration))
    }

    /// Wide: one row. Narrow (FD38): the actions wrap under the title — then fold to icons — and the meta joins
    /// the title's lines, so the title and prompt truncate instead of being squeezed out.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: skin.size.s10) {
                marks
                titleLines(meta: false).frame(minWidth: 0, idealWidth: skin.size.s160, maxWidth: .infinity, alignment: .leading)
                metaText.fixedSize()
                actions(icons: false)
            }
            VStack(alignment: .trailing, spacing: skin.size.s4) {
                HStack(spacing: skin.size.s10) {
                    marks
                    titleLines(meta: true).frame(maxWidth: .infinity, alignment: .leading)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: skin.size.s10) { actions(icons: false) }
                    HStack(spacing: skin.size.s4) { actions(icons: true) }
                }
            }
        }
        .padding(.vertical, skin.size.s6)
        .padding(.horizontal, skin.size.s6)
        .contentShape(Rectangle())
        .onTapGesture { if !group.kept { toggle() } }
    }

    private var marks: some View {
        HStack(spacing: skin.size.s10) {
            Image(systemName: "chevron.right")
                .font(skin.font(AinkradFontToken(sizeKey: "t9", weight: "semibold")))
                .foregroundStyle(skin.color(skin.text.faint))
                .rotationEffect(.degrees(isOpen && !group.kept ? 90 : 0))
                .frame(width: skin.size.s10)
            Circle()
                .fill(group.turn == nil ? theme.accentSecondary.opacity(skin.opacity.o70) : theme.accentPrimary)
                .frame(width: skin.size.s8, height: skin.size.s8)
        }
    }

    private func titleLines(meta: Bool) -> some View {
        VStack(alignment: .leading, spacing: skin.size.s1) {
            Text(group.title)
                .font(skin.font(AinkradFontToken(sizeKey: "t12", weight: "semibold")))
                .lineLimit(1)
            if let line = promptLine, !group.kept {
                Text(line)
                    .font(skin.font(AinkradFontToken(sizeKey: "t11")))
                    .italic(group.turn != nil)
                    .foregroundStyle(skin.color(skin.text.faint))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if meta { metaText }
        }
    }

    private var metaText: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            Text(meta).font(skin.font(AinkradFontToken(sizeKey: "t11"))).foregroundStyle(skin.color(skin.text.muted)).lineLimit(1)
        }
    }

    @ViewBuilder private func actions(icons: Bool) -> some View {
        if group.kept {
            Label("Kept", systemImage: "checkmark").font(skin.font(AinkradFontToken(sizeKey: "t11"))).foregroundStyle(status.success).fixedSize()
        } else {
            if group.turn != nil {
                if icons {
                    AinkradIconButton(systemName: "arrow.turn.down.right", tooltip: "Ask about this turn…") { ask() }
                } else {
                    Label("Ask about this turn…", systemImage: "arrow.turn.down.right")
                        .font(skin.font(AinkradFontToken(sizeKey: "t11")))
                        .foregroundStyle(theme.accentSecondary)
                        .opacity(hovering || asking == group.id ? 1 : skin.opacity.o70)
                        .fixedSize()
                        .onTapGesture { ask() }
                        .help("Ask about this turn in the same Grimoire thread")
                }
            }
            let undoTitle = group.turn == nil ? "Undo" : "Undo turn", keepTitle = group.turn == nil ? "Keep" : "Keep turn"
            if icons {
                AinkradIconButton(systemName: "arrow.uturn.backward", tooltip: undoTitle, action: undo)
                AinkradIconButton(systemName: "checkmark", tooltip: keepTitle) { model.keep(group: group) }
            } else {
                AinkradButton(title: undoTitle, style: .secondary, icon: "arrow.uturn.backward", action: undo).fixedSize()
                AinkradButton(title: keepTitle, style: .primary, icon: "checkmark") { model.keep(group: group) }.fixedSize()
            }
        }
    }

    private func ask() { asking = asking == group.id ? nil : group.id }

    /// The request that caused the turn; for outside edits, which files.
    private var promptLine: String? {
        guard let turn = group.turn else { return group.files.map { ($0.path as NSString).lastPathComponent }.joined(separator: ", ") }
        return turn.prompt.map { "“\($0)”" }
    }

    private var meta: String {
        guard group.turn != nil else {
            let from = group.from.formatted(date: .omitted, time: .shortened)
            let to = group.to.formatted(date: .omitted, time: .shortened)
            return (from == to ? from : "\(from)–\(to)") + " · not from a Grimoire turn"
        }
        let ago = group.to.formatted(.relative(presentation: .named))
        return group.kept ? ago : "Grimoire · " + ago
    }

    private func askField(_ turn: AgentTurn) -> some View {
        AinkradComposer(
            text: $question, placeholder: "Ask \(turn.agent) about this turn…", isEditable: true,
            canSend: !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, autoFocus: true,
            suggestions: { _ in [] }, onPick: { _, _ in }, onDrop: nil,
            onSend: {
                model.askAbout(group, question)
                question = ""
                asking = nil
            },
            chips: { EmptyView() },
            leading: {
                Text("turn \(turn.turn) · \(group.files.count == 1 ? "1 file" : "\(group.files.count) files") attached · Send to Grimoire ⌘↵")
                    .font(skin.font(AinkradFontToken(sizeKey: "t11")))
                    .foregroundStyle(skin.color(skin.text.faint))
                    .lineLimit(1)
            },
            trailing: { EmptyView() })
        .onExitCommand { asking = nil }
    }

    private func fileRow(_ file: TurnLedger.FileChange) -> some View {
        let shown = shownFiles ?? [group.files.first?.path ?? ""]
        let counts = LineMerge.counts(file.before, file.after)
        let folder = (file.path as NSString).deletingLastPathComponent
        let isShown = shown.contains(file.path)
        // Open, the diff's own header names the file (it can't be hidden); the row then only says what happened
        // to it — as Review All does (E1D1 FD13).
        let note = file.before == nil ? "new file" : file.after == nil ? "deleted" : isShown ? nil : folder.isEmpty ? "·" : folder
        return VStack(alignment: .leading, spacing: skin.size.s4) {
            HStack(spacing: skin.size.s8) {
                Image(systemName: isShown ? "chevron.down" : "doc.text").foregroundStyle(skin.color(skin.text.faint))
                if !isShown {
                    Text((file.path as NSString).lastPathComponent).font(skin.font(AinkradFontToken(sizeKey: "t12")))
                        .lineLimit(1).truncationMode(.middle).layoutPriority(1)
                }
                if let note {
                    Text(note)
                        .font(skin.font(AinkradFontToken(sizeKey: "t11", mono: "system")))
                        .foregroundStyle(skin.color(skin.text.faint))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: skin.size.s8)
                Text("+\(counts.added)").foregroundStyle(status.success).fixedSize()
                Text("−\(counts.removed)").foregroundStyle(status.danger).fixedSize()
            }
            .font(skin.font(AinkradFontToken(sizeKey: "t11", mono: "system")))
            .padding(.vertical, skin.size.s3)
            .padding(.horizontal, skin.size.s6)
            .contentShape(Rectangle())
            .onTapGesture {
                var next = shown
                if next.remove(file.path) == nil { next.insert(file.path) }
                shownFiles = next
            }
            if isShown {
                let key = group.id + "|" + file.path
                AinkradDiffReview(
                    fileDiff: ForgeModel.diff(file),
                    rejectedHunkIDs: Binding(get: { model.agent.turns.unticked[key] ?? [] }, set: { model.agent.turns.unticked[key] = $0 }))
            }
        }
    }
}
