import AinkradAppKit
import AppKit
import Foundation

/// Runs `ForgeCommand`s — the single entry point the palette and the shortcut layer share.
extension ForgeModel {
    var availableCommands: [ForgeCommand] {
        ForgeCommand.available(
            hasWorkspace: workspace != nil, hasFile: tabs.active != nil, hasSplit: panes.count > 1,
            inAgentChange: agentChangeAtCaret != nil, agentFile: tabs.active.map { agent.files[$0] != nil } ?? false,
            hintShown: hintShown)
    }

    func run(_ command: ForgeCommand) {
        guard availableCommands.contains(command) else { return }
        palette = nil
        switch command {
        case .quickOpen: palette = ""
        case .commandPalette: palette = ">"
        case .goToLine: palette = ":"
        case .openFolder: if let url = FolderPicker.choose() { request(.open(url)) }
        case .closeWorkspace: request(.close)
        case .save: saveActive()
        case .saveAll: saveAll()
        case .closeTab: if let path = tabs.active { close(path) }
        case .nextTab: cycleTab(by: 1)
        case .previousTab: cycleTab(by: -1)
        case .showFiles: sideTab = .files
        case .showChanges: sideTab = .changes
        case .revealInTree:
            guard let path = tabs.active else { return }
            sideTab = .files
            reveal(path)
        case .refresh: Task { await workspace?.refresh() }
        case .copyPath:
            guard let path = tabs.active, let url = workspace?.url(for: path) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path(percentEncoded: false), forType: .string)
        case .openTerminal: openTerminal()
        case .splitRight: splitEditor(stacked: false)
        case .splitDown: splitEditor(stacked: true)
        case .focusFirstPane: focus(pane: 0)
        case .focusSecondPane: focus(pane: 1)
        case .closePane: closePane()
        case .newFile: beginNew(folder: false, in: tabs.active.map(FileOps.parent(of:)) ?? "")
        case .newFolder: beginNew(folder: true, in: tabs.active.map(FileOps.parent(of:)) ?? "")
        case .renameActiveFile: if let path = tabs.active { beginRename(path) }
        case .revealInFinder:
            if let path = tabs.active, let url = workspace?.url(for: path) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        case .trashActiveFile: if let path = tabs.active { trash(path) }
        case .lineEndingsLF: activeDocument?.convertLineEndings(to: .lf)
        case .lineEndingsCRLF: activeDocument?.convertLineEndings(to: .crlf)
        case .saveAsUTF8: activeDocument?.setEncoding(.utf8)
        case .findInFiles: showSearch()
        case .replaceAll:
            showSearch()
            search.isReplaceOpen = true
            if !search.results.isEmpty { search.confirmingReplaceAll = true }
        case .goToDefinition: goToDefinition()
        case .findReferences: findReferences()
        case .renameSymbol: beginRename()
        case .codeActions: showCodeActions()
        case .formatDocument: formatDocument()
        case .toggleTerminal: terminals.toggle()
        case .newTerminal: terminals.add()
        case .toggleBlame: toggleBlame()
        case .runTask: palette = "!"
        case .rerunLastTask: rerunLastTask()
        case .keepChange: if let at = agentChangeAtCaret { keepChange(at.path, hunk: at.hunk) }
        case .undoChange: if let at = agentChangeAtCaret { undoChange(at.path, hunk: at.hunk) }
        case .keepAllChanges: if let path = tabs.active { keepAllChanges(path) }
        case .askAgent: beginAsk()
        case .showHover: showHoverAtCaret()
        case .closeHints: closeHints()
        case .reviewOutside: agent.reviewingAll = true
        case .showIssues: sideTab = .problems
        case .nextProblem: goToProblem(backward: false)
        case .previousProblem: goToProblem(backward: true)
        case .toggleSidebar: sidebarShown = !isSidebarShown
        case .undoAllChanges: if let path = tabs.active { undoAllChanges(path) }
        case .maximiseTerminal:
            if !terminals.isOpen { terminals.toggle() }
            terminals.isMaximised.toggle()
        }
    }

    /// The palette's `:` mode: jump the active editor to `line` (1-based).
    func goTo(line: Int) {
        palette = nil
        guard line > 0, tabs.active != nil else { return }
        pendingLine = line
        pendingFocus = true
    }

    /// F8 / ⇧F8: the next (previous) issue after the caret, across files in path order, wrapping around.
    private func goToProblem(backward: Bool) {
        let issues = languages.issues.values.joined().sorted { ($0.path, $0.start.line, $0.start.character) < ($1.path, $1.start.line, $1.start.character) }
        let at = tabs.active.flatMap { path in documents[path].map { (path, $0.cursor.line - 1) } }
        guard let index = Self.problem(in: issues.map { ($0.path, $0.start.line) }, after: at, backward: backward) else {
            notice = "No problems."
            return
        }
        open(file: issues[index].path, pinned: false)
        goTo(line: issues[index].start.line + 1)
    }

    /// The index in `positions` (sorted) strictly after — or before — `at`, wrapping; `nil` when empty.
    static func problem(in positions: [(String, Int)], after at: (String, Int)?, backward: Bool) -> Int? {
        guard !positions.isEmpty else { return nil }
        guard let at else { return backward ? positions.count - 1 : 0 }
        if backward { return positions.lastIndex { $0 < at } ?? positions.count - 1 }
        return positions.firstIndex { $0 > at } ?? 0
    }

    private func cycleTab(by step: Int) {
        guard let active = tabs.active, let index = tabs.paths.firstIndex(of: active), tabs.paths.count > 1 else { return }
        let next = (index + step + tabs.paths.count) % tabs.paths.count
        activate(tabs.paths[next])
    }

    private func saveAll() {
        for path in unsavedPaths {
            do {
                try documents[path]?.save()
            } catch {
                notice = "Could not save \(path): \(error.localizedDescription)"
                return
            }
        }
        Task { await workspace?.refresh() }
    }

    /// Rune's app id and launch kind (see Rune's `RuneLaunch`).
    static let terminalAppID = "rune"
    static let openDirectoryKind = "openDirectory"

    /// Opens Rune with a shell in the workspace folder.
    private func openTerminal() {
        guard let apps, let root = workspace?.root,
            let payload = AinkradLaunchIntent(kind: Self.openDirectoryKind, path: root.path(percentEncoded: false)).json
        else { return }
        guard let reporting = apps as? PluginAppLauncherResult else {
            apps.open(appID: Self.terminalAppID, payload: payload)
            return
        }
        switch reporting.openReportingOutcome(appID: Self.terminalAppID, payload: payload) {
        case .opened: break
        case .unknownApp: notice = "Install Rune from the Ainkrad store to open a terminal here."
        case .disabled: notice = "Rune is turned off — enable it in Ainkrad to open a terminal here."
        case .refused(let reason): notice = "Rune didn't open: \(reason)"
        @unknown default: notice = "Rune didn't open."
        }
    }
}
