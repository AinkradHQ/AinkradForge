import AppKit
import ForgeEditor
import ForgeLanguage
import Foundation

/// What the hover card shows: the issues under the pointer, then the server's Markdown about the symbol.
struct HoverInfo: Equatable {
    let pane: Int
    let path: String
    /// Where to anchor the card, in the editor's coordinates.
    let rect: CGRect
    let issues: [Issue]
    let markdown: String?
    let server: String
}

/// The signature of the call the caret is in, pinned over the caret.
struct SignatureInfo: Equatable {
    let pane: Int
    let path: String
    let rect: CGRect
    let hint: SignatureHint
}

/// Language-server requests from the editor: hover, go to definition, find references.
extension ForgeModel {
    /// Starts the window's language servers for a workspace, with the paths set in settings.
    func beginLanguages(root: URL) {
        languages.overrides = editorSettings.serverPaths
        languages.begin(root: root)
    }

    /// Settings changed a server's path: it restarts from there, with the open files that need it.
    func setServerPath(_ specID: String, _ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        editorSettings.serverPaths[specID] = trimmed.isEmpty ? nil : (trimmed as NSString).expandingTildeInPath
        languages.setOverride(specID, path: editorSettings.serverPaths[specID])
        for (file, document) in documents where document.state == .ready && LanguageRegistry.server(for: file)?.0.id == specID {
            languages.opened(path: file, text: document.storage.string)
        }
    }

    /// The pointer rested on `offset` in `path` (or stopped resting, with nil).
    func hover(pane: Int, path: String, at hit: (offset: Int, rect: CGRect)?) async {
        hoverRequest += 1
        let request = hoverRequest
        guard let hit, let document = documents[path], let (spec, _) = LanguageRegistry.server(for: path) else {
            hover = nil
            return
        }
        let index = LineIndex(document.storage.string)
        let position = index.position(of: hit.offset)
        let issues = (languages.issues[path] ?? []).filter { issue in
            let range = index.range(from: issue.start, to: issue.end)
            return NSLocationInRange(hit.offset, range) || (range.length == 0 && range.location == hit.offset)
        }
        let markdown = await languages.hover(path: path, line: position.line, character: position.character)
        guard request == hoverRequest, issues.count + (markdown == nil ? 0 : 1) > 0 else { return }
        hover = HoverInfo(pane: pane, path: path, rect: hit.rect, issues: issues, markdown: markdown, server: spec.command)
    }

    /// Completions at `offset`, for the editor's suggestion window.
    func suggestions(path: String, offset: Int) async -> [EditorSuggestion] {
        guard let document = documents[path] else { return [] }
        let index = LineIndex(document.storage.string)
        let position = index.position(of: offset)
        let found = await languages.completions(path: path, line: position.line, character: position.character)
        // ponytail: the first 500 only; a server's full list for an empty prefix can run to thousands.
        return found.prefix(500).map { item in
            EditorSuggestion(
                label: item.label, kind: Self.kind(item.kind), detail: item.detail, documentation: item.documentation,
                insertText: item.insertText, filterText: item.filterText,
                replaceStart: item.replaceStart.map { index.offset(line: $0.line, character: $0.character) },
                deprecated: item.deprecated)
        }
    }

    /// The caret moved after a signature trigger, or while the hint shows (nil: hide it).
    func signature(pane: Int, path: String, at hit: (offset: Int, rect: CGRect)?) async {
        signatureRequest += 1
        let request = signatureRequest
        guard let hit, let document = documents[path] else {
            signature = nil
            return
        }
        let position = LineIndex(document.storage.string).position(of: hit.offset)
        let hint = await languages.signatureHelp(path: path, line: position.line, character: position.character)
        guard request == signatureRequest else { return }
        signature = hint.map { SignatureInfo(pane: pane, path: path, rect: hit.rect, hint: $0) }
    }

    /// The characters after which `path`'s server offers completions and signature help.
    func triggers(for path: String) -> (completion: Set<String>, signature: Set<String>) {
        guard let (spec, _) = LanguageRegistry.server(for: path) else { return ([], []) }
        return (languages.completionTriggers[spec.id] ?? [], languages.signatureTriggers[spec.id] ?? [])
    }

    private static func kind(_ kind: Completion.Kind) -> EditorSuggestion.Kind {
        switch kind {
        case .method: .method
        case .function: .function
        case .property: .property
        case .variable: .variable
        case .type: .type
        case .keyword: .keyword
        case .snippet: .snippet
        case .module: .module
        case .constant: .constant
        case .other: .other
        }
    }

    /// ⌘-click: definitions of the symbol at `offset`, as links the editor can list and open.
    func definitions(path: String, offset: Int) async -> [EditorLink] {
        guard let document = documents[path] else { return [] }
        let position = LineIndex(document.storage.string).position(of: offset)
        return links(await languages.definition(path: path, line: position.line, character: position.character))
    }

    /// Opens a definition in a preview tab, at its line.
    /// ⌘⌥-click (`inSplit`) opens it in the other pane, splitting the editor first if it is not split.
    func open(_ link: EditorLink, inSplit: Bool = NSEvent.modifierFlags.contains(.option)) {
        guard let root = workspace?.root.path(percentEncoded: false) else { return }
        let base = root.hasSuffix("/") ? root : root + "/"
        guard link.path.hasPrefix(base) else { return }
        if inSplit {
            if panes.count == 1 { splitEditor(stacked: stacked) } else { focus(pane: activePane == 0 ? 1 : 0) }
        }
        open(file: String(link.path.dropFirst(base.count)), pinned: false)
        pendingLine = link.line
    }

    /// Show Hover: the hover card for the symbol at the caret (the keyboard's way to it).
    func showHoverAtCaret() {
        guard let path = tabs.active, let document = documents[path], document.state == .ready else { return }
        let offset = LineIndex(document.storage.string).offset(line: document.cursor.line - 1, character: document.cursor.column - 1)
        let pane = activePane
        let rect = document.caretRect
        Task { await hover(pane: pane, path: path, at: (offset, rect)) }
    }

    /// Whether a hint is up that Esc closes.
    var hintShown: Bool { hover != nil || signature != nil || git.peek != nil || agent.showingWas }

    /// Esc: closes the hover card, the signature hint, the git peek and the Was card.
    func closeHints() {
        hoverRequest += 1
        hover = nil
        signatureRequest += 1
        signature = nil
        git.peek = nil
        agent.showingWas = false
    }

    /// F12: the definition of the symbol at the caret.
    func goToDefinition() {
        guard let (path, line, character) = caret else { return }
        Task {
            let found = links(await languages.definition(path: path, line: line, character: character))
            if let first = found.first { open(first) } else { notice = "No definition found." }
        }
    }

    /// ⇧F12: every reference to the symbol at the caret, in the Search tab. When the server knows none (it
    /// answers from its index, which may not cover the project), a whole-word search stands in, and says so.
    func findReferences() {
        guard let (path, line, character) = caret, let document = documents[path] else { return }
        let lineText = TextSearch.line(line, of: document.storage.string)
        let symbol = TextSearch.word(in: lineText, at: character)
        Task {
            let found = await languages.references(path: path, line: line, character: character)
            sideTab = .search
            guard !found.isEmpty else {
                guard !symbol.isEmpty else { return notice = "No references found." }
                search.query = SearchQuery(text: symbol, matchCase: true, wholeWord: true, regex: false)
                // Now, not on the panel's query change: the panel may only just be appearing, and misses it.
                rerunSearch()
                notice = "The language server found no references to \(symbol), so these are text matches."
                return
            }
            search.showReferences(referenceResults(found), to: symbol)
        }
    }

    /// The active file and its caret as LSP counts it (0-based line, UTF-16 character).
    private var caret: (String, Int, Int)? {
        guard let path = tabs.active, let document = documents[path] else { return nil }
        return (path, document.cursor.line - 1, document.cursor.column - 1)
    }

    private func links(_ locations: [SymbolLocation]) -> [EditorLink] {
        guard let root = workspace?.root else { return [] }
        return locations.map { location in
            EditorLink(
                path: root.appending(path: location.path).path(percentEncoded: false), line: location.start.line + 1,
                label: "\((location.path as NSString).lastPathComponent):\(location.start.line + 1)",
                preview: TextSearch.line(location.start.line, of: text(of: location.path) ?? "")
                    .trimmingCharacters(in: .whitespaces))
        }
    }

    /// References as search results: by file, then line, each highlighting the reference.
    private func referenceResults(_ locations: [SymbolLocation]) -> [SearchModel.FileResult] {
        var results: [SearchModel.FileResult] = []
        for (path, here) in Dictionary(grouping: locations, by: \.path).sorted(by: { $0.key < $1.key }) {
            let text = text(of: path) ?? ""
            let matches = here.sorted { $0.start.line < $1.start.line }.map { location in
                let length = location.end.line == location.start.line ? location.end.character - location.start.character : 0
                return LineMatch(
                    line: location.start.line + 1, text: TextSearch.line(location.start.line, of: text),
                    ranges: [NSRange(location: location.start.character, length: max(0, length))])
            }
            results.append(SearchModel.FileResult(path: path, matches: matches))
        }
        return results
    }

    /// An open file's buffer, else the file on disk.
    func text(of path: String) -> String? {
        if let document = documents[path] { return document.storage.string }
        return workspace.flatMap { SearchModel.readText($0.root.appending(path: path)) }
    }
}
