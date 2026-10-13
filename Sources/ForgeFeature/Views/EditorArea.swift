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
                // The tab row stays above the review (mockups 16, 18); picking a tab leaves the review for later.
                TabRow(model: model) { model.agent.reviewingAll = false }
                ReviewAllPane(model: model)
            } else if let pending = model.pendingEdit {
                // The tabs stay above the preview, as for any editor content.
                TabRow(model: model)
                EditPreview(model: model, pending: pending)
            } else if let preview = model.search.previewPath, model.search.isReplaceOpen, model.sideTab == .search {
                ReplacePreview(model: model, path: preview)
            } else if !(model.terminals.isOpen && model.terminals.isMaximised) {
                TabRow(model: model)
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

/// A pane: the visible file's breadcrumb and editor (its tabs are in the window-wide `TabRow`). The pane commands act on is told apart by
/// the other one dimming slightly — never by a border.
private struct PaneView: View {
    let model: ForgeModel
    let index: Int
    let palette: HostTerminalPalette?
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    @Environment(\.ainkradReduceMotion) private var reduceMotion

    /// The symbols around the caret (`SidebarRow › body`) from the language server, for `path`.
    @State private var trail: (path: String, names: [String]) = ("", [])

    private var tabs: Tabs { model.panes[index] }
    private var isActive: Bool { model.activePane == index || model.panes.count == 1 }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let path = tabs.active, let document = model.documents[path] {
                    VStack(alignment: .leading, spacing: 0) {
                        // One line, never wrapped letter by letter: the whole path down to the caret's symbol when
                        // it fits, else head-truncated with "…", else the file name alone (E1D1 FD27).
                        breadcrumb(path, document: document)
                            .lineLimit(1)
                        .padding(.horizontal, skin.size.s14)
                            .padding(.top, skin.size.s8)
                            .padding(.bottom, skin.size.s4)
                        if let conflict = document.conflict {
                            ConflictBar(document: document, conflict: conflict) { model.close(path) }
                                .padding(.horizontal, skin.size.s10)
                                .padding(.bottom, skin.size.s6)
                        }
                        // Slides in and pushes the code down; no overlay jump (E6).
                        if let bar = model.serverBar(for: path) {
                            ServerBarView(model: model, bar: bar)
                                .padding(.horizontal, skin.size.s10)
                                .padding(.bottom, skin.size.s6)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                        DocumentView(
                            model: model, pane: index, path: path, document: document, palette: palette,
                            goToLine: model.activePane == index ? model.pendingLine : nil)
                        // A wholesale buffer change (reload, line endings) rebuilds the editor so it re-parses.
                        .id("\(path)#\(document.revision)")
                    }
                    .animation(reduceMotion ? nil : skin.animation(skin.motion.present), value: model.serverBar(for: path))
                } else if model.workspace?.files.isEmpty == true {
                    // Nothing to pick in an empty folder (E1D1 FD32): the ways in instead of a blank pane (E6).
                    EmptyEditorHints()
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
                .fill(ForgeStyle.pane(skin, theme))
            )
        }
        .opacity(isActive ? 1 : skin.opacity.o82)
        .task(id: symbolQuery) {
            guard let query = symbolQuery, query.ready else { return }
            // Settles first: a held arrow key asks once, not once per line.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let names = await model.languages.enclosingSymbols(path: query.path, line: query.line - 1, character: query.column - 1)
            if !Task.isCancelled { trail = (query.path, names) }
        }
        .animation(skin.animation(skin.motion.hover), value: isActive)
    }
}

extension PaneView {
    struct SymbolQuery: Equatable {
        let path: String
        let line: Int
        let column: Int
        let ready: Bool
    }

    private var symbolQuery: SymbolQuery? {
        guard let path = tabs.active, let document = model.documents[path], document.state == .ready else { return nil }
        return SymbolQuery(
            path: path, line: document.cursor.line, column: document.cursor.column,
            ready: model.languages.statuses.values.contains(.ready))
    }

    /// `Sources › Ainkrad › ◆ SidebarRow.swift › SidebarRow › body`, in the path's own case.
    @ViewBuilder func breadcrumb(_ path: String, document: EditorDocument) -> some View {
        let parts = path.split(separator: "/").map(String.init)
        let folders = Array(parts.dropLast())
        let file = parts.last ?? path
        let symbols = trail.path == path ? trail.names : []
        ViewThatFits(in: .horizontal) {
            crumbs(folders + [file] + symbols, file: file, at: folders.count)
            if folders.count > 1 { crumbs(["…", folders[folders.count - 1], file] + symbols, file: file, at: 2) }
            if !folders.isEmpty { crumbs(["…", file] + symbols, file: file, at: 1) }
            crumbs([file], file: file, at: 0)
        }
    }

    private func crumbs(_ items: [String], file: String, at index: Int) -> some View {
        AinkradBreadcrumb(items: items).preservesCase().icon(at: index) { FileGlyph(name: file) }
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
        // Filling the pane: under Glass the kit's states are Apple's content-unavailable view, only as wide as its
        // text, and the breadcrumb above them followed it to the middle (E1D1 FD30).
        case .loading:
            AinkradLoadingState(label: "Opening \(document.url.lastPathComponent)…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unreadable(let why):
            AinkradEmptyState(icon: "doc.questionmark", title: "Can't show this file", message: why)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                onCaret: { model.focus(pane: pane) },
                marks: marks + agentMarks.wash
                    + model.searchMarks(in: document.storage.string, color: NSColor(status.warning.opacity(skin.opacity.o30))),
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
                    EditorCardLayer(rect: hover.rect, prefersAbove: false, inset: 0) { HoverCard(info: hover) }
                }
            }
            .overlay {
                if let signature = model.signature, signature.pane == pane, signature.path == path {
                    EditorCardLayer(rect: signature.rect, prefersAbove: true, inset: 0) { SignatureCard(hint: signature.hint) }
                }
            }
            .overlay {
                if let peek = model.git.peek, peek.pane == pane, peek.path == path {
                    EditorCardLayer(rect: peek.rect, prefersAbove: false, interactive: true, inset: 0) { GitPeekCard(model: model, peek: peek) }
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
                            .padding(.leading, max(0, min(anchor.maxX + skin.size.s28, geo.size.width - skin.size.s460 - skin.size.s16)))
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
                    EditorCardLayer(rect: rename.rect, prefersAbove: false, interactive: true, inset: skin.size.s8) {
                        RenameField(model: model, state: rename)
                    }
                }
            }
            }
        }
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
