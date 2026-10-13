import Foundation
internal import LanguageServerProtocol

/// A symbol for quick open's `@` (this file) and `#` (the workspace) modes.
public struct SymbolEntry: Equatable, Sendable {
    public let name: String
    /// The server's kind, as a word: `struct`, `method`, `case`…
    public let kind: String
    /// Workspace-relative.
    public let path: String
    /// 0-based, as LSP reports them.
    public let line: Int
    public let character: Int
    /// The symbol it sits in (`SidebarRow` for its `body`), if any.
    public let container: String?

    public init(name: String, kind: String, path: String, line: Int, character: Int, container: String?) {
        (self.name, self.kind, self.path, self.line, self.character, self.container) = (name, kind, path, line, character, container)
    }
}

extension LanguageHub {
    /// `@`: the file's outline in order, nested symbols after their parent; nil when no server covers the file.
    public func documentSymbols(path: String) async -> [SymbolEntry]? {
        guard let outline = await request(path, { await $0.documentSymbols(uri: $1) }) else { return nil }
        return Self.flatten(outline, path: path, container: nil)
    }

    /// `#`: symbols matching `query` from every running server that offers `workspace/symbol`; `unsupported`
    /// names the running ones that do not.
    public func workspaceSymbols(query: String) async -> (symbols: [SymbolEntry], unsupported: [String]) {
        var symbols: [SymbolEntry] = []
        var unsupported: [String] = []
        for (_, session) in sessions.sorted(by: { $0.key < $1.key }) {
            guard let found = await session.workspaceSymbols(query: query) else {
                unsupported.append(session.spec.command)
                continue
            }
            symbols += found.compactMap { info in
                path(for: info.location.uri).map {
                    SymbolEntry(
                        name: info.name, kind: Self.word(info.kind), path: $0, line: info.location.range.start.line,
                        character: info.location.range.start.character, container: info.containerName)
                }
            }
        }
        return (symbols, unsupported)
    }

    nonisolated static func flatten(_ symbols: [DocumentSymbol], path: String, container: String?) -> [SymbolEntry] {
        symbols.flatMap { symbol in
            [SymbolEntry(
                name: symbol.name, kind: word(symbol.kind), path: path, line: symbol.selectionRange.start.line,
                character: symbol.selectionRange.start.character, container: container)]
                + flatten(symbol.children ?? [], path: path, container: symbol.name)
        }
    }

    nonisolated static func word(_ kind: SymbolKind) -> String {
        switch kind {
        case .enumMember: "case"
        case .typeParameter: "type"
        case .constructor: "init"
        default: String(describing: kind)
        }
    }
}
