import ForgeLanguage
import Foundation

/// Quick open's symbol rows — `@` (this file), `#` (the workspace) and the few file mode shows — as last fetched.
struct PaletteSymbols: Equatable {
    var entries: [SymbolEntry] = []
    /// Why there are none ("pyright can't search the workspace's symbols"), when that is known.
    var note: String?
    /// "#" for the workspace's, "" for the active file's — rows show only in the mode they were fetched for, so a
    /// mode switch never shows the other mode's rows while its own load.
    var scope = ""
}

/// Where the palette opens a file: in place (↵), in the split (⌘↵), or in a new tab group (⌥↵).
enum PaletteTarget { case here, split, newGroup }

extension ForgeModel {
    /// Fetches the symbols the palette's text asks for; `#` waits for typing to pause (the view's task is
    /// cancelled by the next keystroke).
    func loadPaletteSymbols(for text: String) async {
        let (prefix, query) = Palette.split(text)
        guard prefix.isEmpty || prefix == "@" || prefix == "#" else { return }
        if prefix == "#" {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
        }
        var found = await (symbolSource ?? Self.serverSymbols)(self, prefix, query)
        guard !Task.isCancelled else { return }
        found.scope = prefix == "#" ? "#" : ""
        paletteSymbols = found
    }

    private static func serverSymbols(_ model: ForgeModel, prefix: String, query: String) async -> PaletteSymbols {
        if prefix == "#" {
            guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
                return PaletteSymbols(note: "Type a symbol's name to search the workspace.")
            }
            let (found, unsupported) = await model.languages.workspaceSymbols(query: query)
            guard found.isEmpty else { return PaletteSymbols(entries: found) }
            if !unsupported.isEmpty { return PaletteSymbols(note: "\(unsupported.joined(separator: ", ")) can't search the workspace's symbols.") }
            if !model.languages.statuses.values.contains(.ready) {
                return PaletteSymbols(note: "No language server is running — open a source file first.")
            }
            return PaletteSymbols()
        }
        guard let path = model.tabs.active else { return PaletteSymbols(note: "Open a file to go to its symbols.") }
        guard let found = await model.languages.documentSymbols(path: path) else {
            return PaletteSymbols(note: "No language server covers \((path as NSString).lastPathComponent).")
        }
        return PaletteSymbols(entries: found)
    }

    /// Opens `path` from the palette — at `line` (1-based) — in `target`. Forge has two panes at most, so with
    /// a split already open ⌘↵ and ⌥↵ both use the other pane.
    func openFromPalette(_ path: String, line: Int? = nil, in target: PaletteTarget) {
        palette = nil
        if target != .here {
            if panes.count == 1 { splitEditor(stacked: target == .newGroup, showing: path) } else { focus(pane: 1 - activePane) }
        }
        open(file: path, pinned: true)
        if let line { goTo(line: line) }
        // The field that had focus leaves with the palette: hand it to the editor (E1D1 FD8).
        pendingFocus = true
    }
}

extension Palette {
    /// Symbol rows (`struct SidebarRow   SidebarRow.swift:5`). `filter`: rank by the query here (`@`); `#` keeps
    /// the server's own matches and order.
    @MainActor static func symbolItems(
        _ query: String, model: ForgeModel, filter: Bool = true, section: String? = nil, limit: Int = 200
    ) -> [PaletteItem] {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        let entries = model.paletteSymbols.scope == (filter ? "" : "#") ? model.paletteSymbols.entries : []
        let ranked: [SymbolEntry] =
            !filter || needle.isEmpty
            ? entries
            : entries.enumerated()
                .compactMap { index, entry in QuickOpen.subsequenceScore(needle, in: entry.name).map { (entry, $0, index) } }
                .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }
                .map(\.0)
        return ranked.prefix(limit).map { entry in
            // The kind (`struct`, the mockup's `.ty`) leads the row in the type hue.
            PaletteItem(
                id: "symbol:\(entry.path):\(entry.line):\(entry.character):\(entry.name)", title: entry.name,
                glyph: "", kind: entry.kind, detail: "\((entry.path as NSString).lastPathComponent):\(entry.line + 1)",
                payload: .symbol(path: entry.path, line: entry.line + 1), section: section,
                matched: QuickOpen.matchedOffsets(query, in: entry.name))
        }
    }
}
