import SwiftUI

/// A key chord. Command is not implied: `modifiers` is the whole set, so the keycap and the binding agree.
struct Shortcut: Equatable {
    let key: Character
    let modifiers: EventModifiers

    /// e.g. "⌥⌘S", in the order macOS prints modifiers.
    var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + (key == "\r" ? "↵" : String(key).uppercased())
    }
}

/// Every action Forge has. The palette lists them (each wearing its shortcut) and the shortcut layer binds
/// them, from this one list — so nothing is reachable only by knowing where its button is.
enum ForgeCommand: String, CaseIterable, Identifiable {
    case quickOpen, commandPalette, goToLine
    case openFolder, closeWorkspace
    case save, saveAll, closeTab, nextTab, previousTab
    case showFiles, showChanges, revealInTree, refresh
    case copyPath, openTerminal
    case splitRight, splitDown, focusFirstPane, focusSecondPane, closePane
    case newFile, newFolder, renameActiveFile, revealInFinder, trashActiveFile
    case lineEndingsLF, lineEndingsCRLF, saveAsUTF8
    case findInFiles, replaceAll

    var id: String { rawValue }

    enum Requirement { case none, workspace, file, split }

    var title: String {
        switch self {
        case .quickOpen: "Go to File…"
        case .commandPalette: "Show All Commands"
        case .goToLine: "Go to Line…"
        case .openFolder: "Open Folder…"
        case .closeWorkspace: "Close Workspace"
        case .save: "Save"
        case .saveAll: "Save All"
        case .closeTab: "Close Tab"
        case .nextTab: "Next Tab"
        case .previousTab: "Previous Tab"
        case .showFiles: "Show Files"
        case .showChanges: "Show Changes"
        case .revealInTree: "Reveal Active File in Files"
        case .refresh: "Refresh Files and Git Status"
        case .copyPath: "Copy Path of Active File"
        case .openTerminal: "Open Terminal Here (Rune)"
        case .splitRight: "Split Editor Right"
        case .splitDown: "Split Editor Down"
        case .focusFirstPane: "Focus First Pane"
        case .focusSecondPane: "Focus Second Pane"
        case .closePane: "Close Pane"
        case .newFile: "New File…"
        case .newFolder: "New Folder…"
        case .renameActiveFile: "Rename Active File…"
        case .revealInFinder: "Reveal Active File in Finder"
        case .trashActiveFile: "Move Active File to Trash"
        case .lineEndingsLF: "Convert Line Endings to LF"
        case .lineEndingsCRLF: "Convert Line Endings to CRLF"
        case .saveAsUTF8: "Save as UTF-8"
        case .findInFiles: "Find in Files"
        case .replaceAll: "Replace All in Files"
        }
    }

    var systemName: String {
        switch self {
        case .quickOpen: "doc.text.magnifyingglass"
        case .commandPalette: "command"
        case .goToLine: "arrow.right.to.line"
        case .openFolder: "folder"
        case .closeWorkspace: "xmark.square"
        case .save, .saveAll: "square.and.arrow.down"
        case .closeTab: "xmark"
        case .nextTab: "chevron.right"
        case .previousTab: "chevron.left"
        case .showFiles: "sidebar.left"
        case .showChanges: "plusminus"
        case .revealInTree: "scope"
        case .refresh: "arrow.clockwise"
        case .copyPath: "doc.on.clipboard"
        case .openTerminal: "terminal"
        case .splitRight: "rectangle.split.2x1"
        case .splitDown: "rectangle.split.1x2"
        case .focusFirstPane: "1.square"
        case .focusSecondPane: "2.square"
        case .closePane: "xmark.rectangle"
        case .newFile: "doc.badge.plus"
        case .newFolder: "folder.badge.plus"
        case .renameActiveFile: "pencil"
        case .revealInFinder: "folder"
        case .trashActiveFile: "trash"
        case .lineEndingsLF, .lineEndingsCRLF: "return"
        case .saveAsUTF8: "textformat"
        case .findInFiles: "magnifyingglass"
        case .replaceAll: "arrow.left.arrow.right"
        }
    }

    /// VS Code's chords where they exist, so muscle memory carries over.
    var shortcut: Shortcut? {
        switch self {
        case .quickOpen: Shortcut(key: "p", modifiers: .command)
        case .commandPalette: Shortcut(key: "p", modifiers: [.command, .shift])
        case .goToLine: Shortcut(key: "g", modifiers: .control)
        case .openFolder: Shortcut(key: "o", modifiers: .command)
        case .save: Shortcut(key: "s", modifiers: .command)
        case .saveAll: Shortcut(key: "s", modifiers: [.command, .option])
        case .closeTab: Shortcut(key: "w", modifiers: .command)
        case .nextTab: Shortcut(key: "]", modifiers: [.command, .shift])
        case .previousTab: Shortcut(key: "[", modifiers: [.command, .shift])
        case .showFiles: Shortcut(key: "e", modifiers: [.command, .shift])
        case .showChanges: Shortcut(key: "g", modifiers: [.control, .shift])
        case .copyPath: Shortcut(key: "c", modifiers: [.command, .option])
        case .splitRight: Shortcut(key: "\\", modifiers: .command)
        case .focusFirstPane: Shortcut(key: "1", modifiers: .command)
        case .focusSecondPane: Shortcut(key: "2", modifiers: .command)
        case .newFile: Shortcut(key: "n", modifiers: .command)
        case .newFolder: Shortcut(key: "n", modifiers: [.command, .option])
        case .revealInFinder: Shortcut(key: "r", modifiers: [.command, .option])
        case .findInFiles: Shortcut(key: "f", modifiers: [.command, .shift])
        case .replaceAll: Shortcut(key: "\r", modifiers: [.command, .option])
        case .closeWorkspace, .revealInTree, .refresh, .openTerminal, .splitDown, .closePane, .renameActiveFile,
            .trashActiveFile, .lineEndingsLF, .lineEndingsCRLF, .saveAsUTF8:
            nil
        }
    }

    var requirement: Requirement {
        switch self {
        case .quickOpen, .commandPalette, .openFolder: .none
        case .closeWorkspace, .saveAll, .showFiles, .showChanges, .refresh, .openTerminal, .newFile, .newFolder,
            .findInFiles, .replaceAll:
            .workspace
        case .goToLine, .save, .closeTab, .nextTab, .previousTab, .revealInTree, .copyPath, .splitRight, .splitDown,
            .renameActiveFile, .revealInFinder, .trashActiveFile, .lineEndingsLF, .lineEndingsCRLF, .saveAsUTF8:
            .file
        case .focusFirstPane, .focusSecondPane, .closePane: .split
        }
    }

    /// The commands that can run now, in registry order.
    static func available(hasWorkspace: Bool, hasFile: Bool, hasSplit: Bool = false) -> [ForgeCommand] {
        allCases.filter {
            switch $0.requirement {
            case .none: true
            case .workspace: hasWorkspace
            case .file: hasFile
            case .split: hasSplit
            }
        }
    }

    /// The palette's `>` mode: title words in order, best first.
    static func matching(_ query: String, in commands: [ForgeCommand]) -> [ForgeCommand] {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return commands }
        return commands
            .compactMap { command in QuickOpen.subsequenceScore(needle, in: command.title).map { (command, $0) } }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }
}
