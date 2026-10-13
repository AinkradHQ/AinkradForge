import AinkradAppKit
import ForgeEditor
import ForgeLanguage
import SwiftUI

/// One or two editor panes and the status bar — one surface, no rules.
struct EditorArea: View {
    let model: ForgeModel
    let workspace: Workspace
    let palette: HostTerminalPalette?
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            if model.agent.reviewingAll {
                ReviewAllPane(model: model)
            } else if let pending = model.pendingEdit {
                EditPreview(model: model, pending: pending)
            } else if let preview = model.search.previewPath, model.search.isReplaceOpen, model.sideTab == .search {
                ReplacePreview(model: model, path: preview)
            } else if !(model.terminals.isOpen && model.terminals.isMaximised) {
                let layout = model.stacked ? AnyLayout(VStackLayout(spacing: skin.size.s10)) : AnyLayout(HStackLayout(spacing: skin.size.s10))
                layout {
                    ForEach(model.panes.indices, id: \.self) { index in
                        PaneView(model: model, index: index, palette: palette)
                    }
                }
                .padding(.horizontal, skin.size.s14)
            }
            if model.terminals.isOpen {
                TerminalDrawerView(model: model)
                    .padding(.horizontal, skin.size.s14)
                    .padding(.top, skin.size.s10)
            }
            StatusRow(model: model, workspace: workspace)
        }
        .onAppear { model.terminals.restyle(palette, foreground: NSColor(theme.foreground)) }
        .onChange(of: palette) { _, palette in model.terminals.restyle(palette, foreground: NSColor(theme.foreground)) }
        .onChange(of: theme.foreground) { _, foreground in model.terminals.restyle(palette, foreground: NSColor(foreground)) }
    }
}

/// A pane: its tabs, the visible file's breadcrumb and editor. The pane commands act on is told apart by
/// the other one dimming slightly — never by a border.
private struct PaneView: View {
    let model: ForgeModel
    let index: Int
    let palette: HostTerminalPalette?
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    private var tabs: Tabs { model.panes[index] }
    private var isActive: Bool { model.activePane == index || model.panes.count == 1 }

    var body: some View {
        VStack(spacing: 0) {
            TabStrip(model: model, pane: index)
            Group {
                if let path = tabs.active, let document = model.documents[path] {
                    VStack(alignment: .leading, spacing: 0) {
                        AinkradBreadcrumb(items: path.split(separator: "/").map(String.init))
                            .padding(.horizontal, skin.size.s14)
                            .padding(.top, skin.size.s8)
                            .padding(.bottom, skin.size.s4)
                        if let conflict = document.conflict {
                            ConflictBar(document: document, conflict: conflict) { model.close(path) }
                                .padding(.horizontal, skin.size.s10)
                                .padding(.bottom, skin.size.s6)
                        }
                        DocumentView(
                            model: model, pane: index, path: path, document: document, palette: palette,
                            goToLine: model.activePane == index ? model.pendingLine : nil)
                        // A wholesale buffer change (reload, line endings) rebuilds the editor so it re-parses.
                        .id("\(path)#\(document.revision)")
                    }
                } else {
                    AinkradEmptyState(
                        icon: "doc.text", title: "No file open",
                        message: "Pick a file in the sidebar. A single click previews it; a double click keeps it open.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // CodeEdit's gutter is a sibling of its scroll view sized to the whole document: without a clip
            // it draws past the pane (into the other pane when stacked).
            .clipped()
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: tabs.paths.isEmpty ? skin.size.s10 : 0, bottomLeadingRadius: skin.size.s10,
                    bottomTrailingRadius: skin.size.s10, topTrailingRadius: skin.size.s10
                )
                .fill(theme.surface.opacity(skin.opacity.o45))
            )
        }
        .opacity(isActive ? 1 : skin.opacity.o82)
        .animation(skin.animation(skin.motion.hover), value: isActive)
    }
}

private struct DocumentView: View {
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradStatusColors) private var status
    @Environment(\.ainkradTheme) private var theme

    /// The issues as underlines: LSP (line, character) mapped onto the buffer the server was sent.
    private var marks: [EditorMark] {
        guard !issues.isEmpty else { return [] }
        let index = LineIndex(document.storage.string)
        return issues.map { issue in
            EditorMark(
                range: index.range(from: issue.start, to: issue.end),
                color: NSColor(IssueStyle.color(issue.severity, status: status, theme: theme)))
        }
    }

    let model: ForgeModel
    let pane: Int
    let path: String
    let document: EditorDocument
    let palette: HostTerminalPalette?
    let goToLine: Int?

    private var issues: [Issue] { model.languages.issues[path] ?? [] }
    private var isFirstPane: Bool { model.panes.firstIndex { $0.active == path } == pane }
    private var lineCount: Int { document.storage.string.utf8.reduce(1) { $1 == 10 ? $0 + 1 : $0 } }

    /// The ruler's marks: issues by severity, git changes, outside changes.
    private var overview: [OverviewRuler.Mark] {
        var marks = issues.map { OverviewRuler.Mark(line: $0.start.line + 1, color: IssueStyle.color($0.severity, status: status, theme: theme)) }
        for hunk in model.git.hunks[path] ?? [] {
            let color = hunk.newCount == 0 ? status.danger : hunk.oldCount == 0 ? status.success : status.warning
            marks += (hunk.newStart...max(hunk.newStart, hunk.newStart + hunk.newCount - 1)).map { OverviewRuler.Mark(line: max(1, $0), color: color) }
        }
        marks += model.agent.lines(path).written.map { OverviewRuler.Mark(line: $0, color: theme.accentSecondary) }
        return marks
    }

    /// Where the current outside change's first line is, as the editor last reported it.
    @State private var anchor: CGRect?

    var body: some View {
        switch document.state {
        case .loading: AinkradLoadingState(label: "Opening \(document.url.lastPathComponent)…")
        case .unreadable(let why):
            AinkradEmptyState(icon: "doc.questionmark", title: "Can't show this file", message: why)
        case .ready:
            let review = model.agent.files[path]
            let agentMarks = model.agentMarks(path, color: NSColor(theme.accentSecondary))
            let hunk = model.agent.current[path] ?? 0
            VStack(spacing: 0) {
                if let review {
                    ReviewBar(model: model, path: path, file: review)
                        .padding(.horizontal, skin.size.s10)
                        .padding(.bottom, skin.size.s6)
                }
            CodeEditor(
                document: document, palette: palette, options: model.editorOptions, goToLine: goToLine,
                onGoToLineHandled: { model.pendingLine = nil },
                focus: model.activePane == pane && model.pendingFocus, onFocusHandled: { model.pendingFocus = false },
                // The caret moved here — this pane is the one being worked in.
                onCaret: { model.focus(pane: pane) }, marks: marks + agentMarks.wash,
                definitions: { [model, path] offset in await model.definitions(path: path, offset: offset) },
                onOpenLink: { [model] link in model.open(link) },
                onHover: { [model, pane, path] hit in Task { await model.hover(pane: pane, path: path, at: hit) } },
                suggest: { [model, path] offset in await model.suggestions(path: path, offset: offset) },
                suggestionTriggers: model.triggers(for: path).completion,
                signatureTriggers: model.triggers(for: path).signature,
                signatureShown: model.signature?.pane == pane && model.signature?.path == path,
                onSignature: { [model, pane, path] hit in Task { await model.signature(pane: pane, path: path, at: hit) } },
                // Edits and the action menu go to the first pane showing the file only: panes share its buffer.
                edits: isFirstPane ? model.editorEdits[path] : nil,
                onEditsApplied: { [model, path] id in if model.editorEdits[path]?.id == id { model.editorEdits[path] = nil } },
                menu: pane == model.activePane ? model.actionMenu : nil,
                onMenuPick: { [model] index in model.pickCodeAction(index) },
                onCaretRect: { [document, model] rect, lineEnd in
                    document.caretRect = rect
                    document.caretLineEnd = lineEnd
                    model.blameCaret()
                },
                lineMarks: model.git.marks(path, status: status) + agentMarks.gutter,
                onLineMarkClick: { [model, pane, path] tag, rect in
                    if tag >= ForgeModel.agentTagBase {
                        model.agent.current[path] = tag - ForgeModel.agentTagBase
                    } else {
                        model.peekChange(pane: pane, path: path, hunk: tag, rect: rect)
                    }
                },
                anchorLine: review == nil ? nil : model.agent.anchorLine(path, hunk: hunk),
                onAnchor: { anchor = $0 }
            ) { model.didEdit(path) }
            .overlay {
                if let hover = model.hover, hover.pane == pane, hover.path == path {
                    EditorCardLayer(rect: hover.rect, prefersAbove: false) { HoverCard(info: hover) }
                }
            }
            .overlay {
                if let signature = model.signature, signature.pane == pane, signature.path == path {
                    EditorCardLayer(rect: signature.rect, prefersAbove: true) { SignatureCard(hint: signature.hint) }
                }
            }
            .overlay {
                if let peek = model.git.peek, peek.pane == pane, peek.path == path {
                    EditorCardLayer(rect: peek.rect, prefersAbove: false, interactive: true) { GitPeekCard(model: model, peek: peek) }
                }
            }
            .overlay(alignment: .topLeading) {
                if let note = model.git.blame, note.path == path, pane == model.activePane {
                    BlameView(model: model, note: note)
                        .padding(.leading, document.caretLineEnd + skin.size.s28)
                        .padding(.top, document.caretRect.minY)
                }
            }
            .overlay { OverviewRuler(marks: overview, lineCount: lineCount) }
            .overlay(alignment: .topLeading) {
                if review != nil, let anchor {
                    // At the line's end, but never so far right that the Was card leaves the editor.
                    GeometryReader { geo in
                        ChangeChip(model: model, path: path, hunk: hunk)
                            .padding(.leading, max(0, min(anchor.maxX + skin.size.s28, geo.size.width - skin.size.s420 - skin.size.s16)))
                            .padding(.top, max(0, anchor.minY - skin.size.s2))
                    }
                }
            }
            .overlay {
                if let ask = model.agent.ask, ask.pane == pane, ask.path == path {
                    EditorCardLayer(rect: ask.rect, prefersAbove: false, interactive: true) { AskAgentCard(model: model, request: ask) }
                }
            }
            .overlay {
                if let rename = model.rename, rename.pane == pane, rename.path == path {
                    EditorCardLayer(rect: rename.rect, prefersAbove: false, interactive: true) {
                        RenameField(model: model, state: rename)
                    }
                }
            }
            }
        }
    }
}

/// A pane's open files. The visible tab shares the pane's fill, so it reads as part of it.
private struct TabStrip: View {
    let model: ForgeModel
    let pane: Int
    @Environment(\.ainkradSkin) private var skin

    private var tabs: Tabs { model.panes[pane] }

    var body: some View {
        // The active tab is kept in view: opening a tenth file must not leave it past the edge (E1D1 FD29).
        ScrollViewReader { proxy in
            strip
                .onAppear { if let active = tabs.active { proxy.scrollTo(active) } }
                .onChange(of: tabs.active) { _, active in
                    guard let active else { return }
                    withAnimation(skin.animation(skin.motion.hover)) { proxy.scrollTo(active) }
                }
        }
    }

    private var strip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: skin.size.s2) {
                ForEach(tabs.paths, id: \.self) { path in
                    EditorTab(
                        name: (path as NSString).lastPathComponent,
                        isActive: tabs.active == path, isPreview: tabs.preview == path,
                        isDirty: model.documents[path]?.isDirty == true
                    ) {
                        model.focus(pane: pane)
                        model.activate(path)
                    } onDoubleClick: {
                        model.focus(pane: pane)
                        model.pin(path)
                    } onClose: {
                        model.focus(pane: pane)
                        model.close(path)
                    }
                    .help(path)
                }
            }
            .padding(.horizontal, skin.size.s14)
        }
        .scrollIndicators(.never)
        .padding(.top, skin.size.s12)
        .frame(height: skin.size.s44, alignment: .bottom)
    }
}

private struct EditorTab: View {
    let name: String
    let isActive: Bool
    let isPreview: Bool
    let isDirty: Bool
    let onSelect: () -> Void
    let onDoubleClick: () -> Void
    let onClose: () -> Void
    @State private var isHovered = false
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        HStack(spacing: skin.size.s6) {
            Image(systemName: FileIcon.symbol(for: FileNode(path: name, name: name, isDirectory: false, children: [])))
                .font(skin.font(AinkradFontToken(sizeKey: "t10")))
                .foregroundStyle(FileIcon.tint(for: name, theme: theme) ?? skin.color(skin.text.faint))
            Text(name)
                .font(skin.font(AinkradFontToken(sizeKey: "t12", weight: isActive ? "medium" : "regular")))
                .italic(isPreview)
                .foregroundStyle(isActive ? theme.foreground : skin.color(skin.text.muted))
                .lineLimit(1)
            // The dirty dot gives way to ✕ while hovered, as in Xcode.
            ZStack {
                if isDirty && !isHovered {
                    Circle().fill(theme.foreground.opacity(skin.opacity.o70)).frame(width: skin.size.s7, height: skin.size.s7)
                } else if isHovered || isActive {
                    AinkradIconButton(systemName: "xmark", size: skin.size.s16, tooltip: "Close (⌘W)", action: onClose)
                }
            }
            .frame(width: skin.size.s16, height: skin.size.s16)
        }
        .padding(.vertical, skin.size.s7)
        .padding(.leading, skin.size.s12)
        .padding(.trailing, skin.size.s6)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: skin.size.s8, topTrailingRadius: skin.size.s8)
                .fill(isActive ? theme.surface.opacity(skin.opacity.o45) : isHovered ? theme.foreground.opacity(skin.opacity.o05) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2, perform: onDoubleClick)
        .simultaneousGesture(TapGesture().onEnded(onSelect))
    }
}

/// The file changed on disk while it had unsaved edits, or disappeared: keep the buffer, or take the disk.
private struct ConflictBar: View {
    let document: EditorDocument
    let conflict: EditorDocument.Conflict
    let close: () -> Void

    var body: some View {
        let name = document.url.lastPathComponent
        switch conflict {
        case .modified:
            AinkradDecisionBar(
                icon: "exclamationmark.arrow.triangle.2.circlepath", iconTint: .primary, caption: "Changed on disk",
                title: "\(name) was changed outside Forge while you had unsaved edits.",
                actions: [
                    .init(title: "Keep Mine", style: .ghost) { Task { await document.resolveConflict(reload: false) } },
                    .init(title: "Reload", style: .primary) { Task { await document.resolveConflict(reload: true) } },
                ])
        case .deleted:
            AinkradDecisionBar(
                icon: "trash", iconTint: .secondary, caption: "Deleted on disk",
                title: "\(name) no longer exists. Saving writes it back.",
                actions: [
                    .init(title: "Close", style: .ghost, perform: close),
                    .init(title: "Keep Editing", style: .primary) { Task { await document.resolveConflict(reload: false) } },
                ])
        }
    }
}

/// Branch, cursor, line endings, encoding and language. Language-server state joins with E5.
private struct StatusRow: View {
    let model: ForgeModel
    let workspace: Workspace
    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        HStack(spacing: skin.size.s14) {
            if let branch = workspace.branch {
                Label(branch, systemImage: "arrow.triangle.branch")
            }
            IssueCounts(model: model)
            ServerChip(model: model)
            OutsideChangesButton(model: model)
            if workspace.isLoading { AinkradSpinner() }
            Spacer(minLength: skin.size.s8)
            if let document = model.activeDocument, document.state == .ready {
                Text("Ln \(document.cursor.line), Col \(document.cursor.column)")
                StatusMenu(title: document.format.lineEnding.rawValue, items: TextFormat.LineEnding.allCases.map { ending in
                    AinkradMenuItem(title: "Convert to \(ending.rawValue)", systemName: ending == document.format.lineEnding ? "checkmark" : nil) {
                        document.convertLineEndings(to: ending)
                    }
                })
                StatusMenu(title: document.format.encoding.rawValue, items: TextFormat.Encoding.allCases.map { encoding in
                    AinkradMenuItem(title: "Save as \(encoding.rawValue)", systemName: encoding == document.format.encoding ? "checkmark" : nil) {
                        document.setEncoding(encoding)
                    }
                })
                Text(document.language.name)
            }
        }
        .font(skin.font(AinkradFontToken(sizeKey: "t11", monospacedDigits: true)))
        .foregroundStyle(skin.color(skin.text.muted))
        .lineLimit(1)
        .padding(.horizontal, skin.size.s18)
        .padding(.vertical, skin.size.s8)
    }
}

/// A status-bar item that opens a pull-down menu — plain text until hovered, like the rest of the bar.
private struct StatusMenu: View {
    let title: String
    let items: [AinkradMenuItem]
    @State private var isHovered = false
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        AinkradMenuButton(items: items) {
            Text(title)
                .foregroundStyle(isHovered ? theme.foreground : skin.color(skin.text.muted))
                .onHover { isHovered = $0 }
        }
    }
}

/// ⊗ errors ⚠ warnings — opens the Issues tab.
private struct IssueCounts: View {
    let model: ForgeModel
    @Environment(\.ainkradStatusColors) private var status
    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        if !model.languages.statuses.isEmpty {
            HStack(spacing: skin.size.s6) {
                Label("\(model.languages.errorCount)", systemImage: "xmark.octagon")
                    .foregroundStyle(model.languages.errorCount > 0 ? status.danger : skin.color(skin.text.muted))
                Label("\(model.languages.warningCount)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(model.languages.warningCount > 0 ? status.warning : skin.color(skin.text.muted))
            }
            .contentShape(Rectangle())
            .onTapGesture { model.sideTab = .problems }
            .help("Show issues")
        }
    }
}

/// The active file's language server and its state; the menu lists every server the workspace uses.
private struct ServerChip: View {
    let model: ForgeModel
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradStatusColors) private var status

    var body: some View {
        if let path = model.tabs.active, let (spec, _) = LanguageRegistry.server(for: path) {
            let state = model.languages.statuses[spec.id] ?? .notRunning
            AinkradMenuButton(items: items) {
                HStack(spacing: skin.size.s4) {
                    Circle().fill(color(state)).frame(width: skin.size.s6, height: skin.size.s6)
                    Text(spec.command)
                }
            }
            .help(Self.describe(state, spec: spec))
        }
    }

    private var items: [AinkradMenuItem] {
        let used = LanguageRegistry.servers.filter { model.languages.statuses[$0.id] != nil }
        var items = used.map { spec in
            let state = model.languages.statuses[spec.id] ?? .notRunning
            return AinkradMenuItem(title: "\(spec.command) — \(Self.describe(state, spec: spec))", systemName: nil) {}
        }
        for spec in used where model.languages.statuses[spec.id] != .notInstalled {
            items.append(AinkradMenuItem(title: "Restart \(spec.command)", systemName: "arrow.clockwise") {
                model.languages.restart(spec.id)
            })
        }
        return items
    }

    private func color(_ state: ServerStatus) -> Color {
        switch state {
        case .ready: status.success
        case .starting: theme.accentSecondary
        case .failed, .notInstalled: status.warning
        case .notRunning: skin.color(skin.text.faint)
        }
    }

    static func describe(_ state: ServerStatus, spec: ServerSpec) -> String {
        switch state {
        case .ready: "ready"
        case .starting: "starting…"
        case .notRunning: "not running"
        case .notInstalled: "not installed — \(spec.installHint)"
        case .failed(let why): "failed: \(why)"
        }
    }
}

