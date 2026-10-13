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
        return text + (key == "\r" ? "↵" : key == Self.backspace ? "⌫" : key == Self.escape ? "Esc" : key == Self.f12 ? "F12" : key == Self.f2 ? "F2" : key == Self.f8 ? "F8" : String(key).uppercased())
    }

    /// AppKit's private-use characters for the function keys.
    static let f2 = Character("\u{F705}")
    static let f8 = Character("\u{F70B}")
    static let backspace = Character("\u{7F}")
    static let escape = Character("\u{1B}")
    static let f12 = Character("\u{F70F}")
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
    case goToDefinition, findReferences, renameSymbol, codeActions, formatDocument
    case toggleTerminal, newTerminal, maximiseTerminal, toggleBlame, runTask, rerunLastTask
    case keepChange, undoChange, keepAllChanges, undoAllChanges, askAgent, showHover, closeHints
    case reviewOutside, showIssues, nextProblem, previousProblem, toggleSidebar

    var id: String { rawValue }

    enum Requirement { case none, workspace, file, split, agentChange, agentFile, hint }

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
        case .goToDefinition: "Go to Definition"
        case .findReferences: "Find References"
        case .renameSymbol: "Rename Symbol"
        case .codeActions: "Quick Fix…"
        case .formatDocument: "Format Document"
        case .toggleTerminal: "Toggle Terminal"
        case .newTerminal: "New Terminal"
        case .maximiseTerminal: "Maximise Terminal"
        case .toggleBlame: "Toggle Blame"
        case .runTask: "Run Task…"
        case .rerunLastTask: "Rerun Last Task"
        case .keepChange: "Keep Outside Change"
        case .undoChange: "Undo Outside Change"
        case .keepAllChanges: "Keep All Outside Changes in File"
        case .undoAllChanges: "Undo All Outside Changes in File"
        case .askAgent: "Ask Agent…"
        case .showHover: "Show Hover"
        case .closeHints: "Close Hint"
        case .reviewOutside: "Review Changes Made Outside Forge"
        case .showIssues: "Show Issues"
        case .nextProblem: "Go to Next Problem"
        case .previousProblem: "Go to Previous Problem"
        case .toggleSidebar: "Toggle Sidebar"
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
        case .goToDefinition: "arrow.turn.down.right"
        case .findReferences: "list.bullet.indent"
        case .renameSymbol: "character.cursor.ibeam"
        case .codeActions: "lightbulb"
        case .formatDocument: "text.alignleft"
        case .toggleTerminal, .newTerminal: "terminal"
        case .maximiseTerminal: "arrow.up.left.and.arrow.down.right"
        case .toggleBlame: "person.text.rectangle"
        case .runTask: "play"
        case .rerunLastTask: "arrow.clockwise"
        case .keepChange, .keepAllChanges: "checkmark"
        case .undoChange, .undoAllChanges: "arrow.uturn.backward"
        case .askAgent: "sparkles"
        case .showHover: "text.bubble"
        case .closeHints: "xmark"
        case .reviewOutside: "sparkle"
        case .showIssues: "exclamationmark.triangle"
        case .nextProblem: "arrow.down.to.line"
        case .previousProblem: "arrow.up.to.line"
        case .toggleSidebar: "sidebar.left"
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
        case .goToDefinition: Shortcut(key: Shortcut.f12, modifiers: [])
        case .findReferences: Shortcut(key: Shortcut.f12, modifiers: .shift)
        case .renameSymbol: Shortcut(key: Shortcut.f2, modifiers: [])
        case .codeActions: Shortcut(key: ".", modifiers: .command)
        case .formatDocument: Shortcut(key: "f", modifiers: [.option, .shift])
        case .toggleTerminal: Shortcut(key: "`", modifiers: .control)
        case .newTerminal: Shortcut(key: "`", modifiers: [.control, .shift])
        case .maximiseTerminal: Shortcut(key: "m", modifiers: [.command, .shift])
        case .toggleBlame: Shortcut(key: "b", modifiers: [.command, .option])
        // ⇧⌘B is VS Code's Run Build Task (⌥⌘R stays Reveal in Finder).
        case .runTask: Shortcut(key: "b", modifiers: [.command, .shift])
        case .rerunLastTask: Shortcut(key: "b", modifiers: [.command, .shift, .control])
        // Claimed only while the caret is in an outside change (`.agentChange`): ⌘⌫ deletes to the line's
        // start everywhere else.
        case .keepChange: Shortcut(key: "\r", modifiers: .command)
        case .undoChange: Shortcut(key: Shortcut.backspace, modifiers: .command)
        case .askAgent: Shortcut(key: "i", modifiers: .command)
        // Claimed only while a hint shows (`.hint`): Esc reaches the editor otherwise.
        case .closeHints: Shortcut(key: Shortcut.escape, modifiers: [])
        case .nextProblem: Shortcut(key: Shortcut.f8, modifiers: [])
        case .previousProblem: Shortcut(key: Shortcut.f8, modifiers: .shift)
        // Xcode's navigator chord: VS Code's ⌘B is Bold wherever a text menu is installed.
        case .toggleSidebar: Shortcut(key: "0", modifiers: .command)
        case .closeWorkspace, .revealInTree, .refresh, .openTerminal, .splitDown, .closePane, .renameActiveFile,
            .trashActiveFile, .lineEndingsLF, .lineEndingsCRLF, .saveAsUTF8, .keepAllChanges, .undoAllChanges, .showHover,
            .reviewOutside, .showIssues:
            nil
        }
    }

    var requirement: Requirement {
        switch self {
        case .quickOpen, .commandPalette, .openFolder: .none
        case .closeWorkspace, .saveAll, .showFiles, .showChanges, .refresh, .openTerminal, .newFile, .newFolder,
            .findInFiles, .replaceAll, .toggleTerminal, .newTerminal, .maximiseTerminal, .runTask, .rerunLastTask,
            .reviewOutside, .showIssues, .nextProblem, .previousProblem, .toggleSidebar:
            .workspace
        case .goToLine, .save, .closeTab, .nextTab, .previousTab, .revealInTree, .copyPath, .splitRight, .splitDown,
            .renameActiveFile, .revealInFinder, .trashActiveFile, .lineEndingsLF, .lineEndingsCRLF, .saveAsUTF8,
            .goToDefinition, .findReferences, .renameSymbol, .codeActions, .formatDocument, .toggleBlame, .askAgent, .showHover:
            .file
        case .focusFirstPane, .focusSecondPane, .closePane: .split
        case .keepChange, .undoChange: .agentChange
        case .keepAllChanges, .undoAllChanges: .agentFile
        case .closeHints: .hint
        }
    }

    /// The commands that can run now, in registry order.
    static func available(
        hasWorkspace: Bool, hasFile: Bool, hasSplit: Bool = false, inAgentChange: Bool = false, agentFile: Bool = false,
        hintShown: Bool = false
    ) -> [ForgeCommand] {
        allCases.filter {
            switch $0.requirement {
            case .none: true
            case .workspace: hasWorkspace
            case .file: hasFile
            case .split: hasSplit
            case .agentChange: inAgentChange
            case .agentFile: agentFile
            case .hint: hintShown
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
