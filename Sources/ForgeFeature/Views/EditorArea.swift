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
                        // One line, never wrapped letter by letter: the whole path when it fits, else the file name,
                        // truncated if even that is too long (E1D1 FD27).
                        ViewThatFits(in: .horizontal) {
                            AinkradBreadcrumb(items: path.split(separator: "/").map(String.init))
                            AinkradBreadcrumb(items: [(path as NSString).lastPathComponent])
                        }
                        .lineLimit(1)
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
                } else if model.workspace?.files.isEmpty == true {
                    // Nothing to pick in an empty folder (E1D1 FD32).
                    AinkradEmptyState(icon: "doc.text", title: "No file open", message: "This folder has no files yet. New File (⌘N) creates one.")
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
                    BlameView(model: model, note: note, leading: document.caretLineEnd + skin.size.s28)
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
        // No scroll bar: an edge with tabs past it fades out instead, so more tabs read as there (E1D1 FD29).
        .modifier(OverflowFade())
        .padding(.top, skin.size.s12)
        .frame(height: skin.size.s44, alignment: .bottom)
    }
}

/// Fades a horizontal scroll view's edge while content is scrolled out past it. macOS 15+ (scroll geometry);
/// earlier, no fade.
private struct OverflowFade: ViewModifier {
    /// Leading, trailing.
    @State private var hidden = [false, false]
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content
                .onScrollGeometryChange(for: [Bool].self) { geometry in
                    let offset = geometry.contentOffset.x
                    return [offset > 1, offset + geometry.containerSize.width < geometry.contentSize.width - 1]
                } action: { _, edges in
                    hidden = edges
                }
                .mask {
                    HStack(spacing: 0) {
                        LinearGradient(colors: [.clear, theme.foreground], startPoint: .leading, endPoint: .trailing)
                            .frame(width: hidden[0] ? skin.size.s28 : 0)
                        Rectangle()
                        LinearGradient(colors: [theme.foreground, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: hidden[1] ? skin.size.s28 : 0)
                    }
                }
        } else {
            content
        }
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
