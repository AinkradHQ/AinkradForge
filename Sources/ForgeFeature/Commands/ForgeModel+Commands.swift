import AinkradAppKit
import AppKit
import Foundation

/// Runs `ForgeCommand`s — the single entry point the palette and the shortcut layer share.
extension ForgeModel {
    var availableCommands: [ForgeCommand] {
        ForgeCommand.available(hasWorkspace: workspace != nil, hasFile: tabs.active != nil, hasSplit: panes.count > 1)
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
        }
    }

    /// The palette's `:` mode: jump the active editor to `line` (1-based).
    func goTo(line: Int) {
        palette = nil
        guard line > 0, tabs.active != nil else { return }
        pendingLine = line
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
