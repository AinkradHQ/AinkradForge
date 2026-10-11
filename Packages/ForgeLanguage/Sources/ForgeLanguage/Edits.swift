import Foundation
internal import LanguageServerProtocol

/// One text replacement a server asks for (0-based line, UTF-16 character).
public struct TextChange: Sendable {
    public let start: (line: Int, character: Int)
    public let end: (line: Int, character: Int)
    public let newText: String

    public init(start: (line: Int, character: Int), end: (line: Int, character: Int), newText: String) {
        self.start = start
        self.end = end
        self.newText = newText
    }

    /// `text` with `changes` made (each range read against the original, as LSP specifies).
    public static func apply(_ changes: [TextChange], to text: String) -> String {
        let index = LineIndex(text)
        let out = NSMutableString(string: text)
        let ranges = changes.map { (index.range(from: $0.start, to: $0.end), $0.newText) }
        for (range, newText) in ranges.sorted(by: { $0.0.location > $1.0.location }) {
            out.replaceCharacters(in: range, with: newText)
        }
        return out as String
    }
}

/// A fix or refactor the server offers at the caret.
public struct CodeActionItem: Sendable {
    public let title: String
    /// e.g. "quickfix", "refactor.extract".
    public let kind: String?
    public let isPreferred: Bool
    let action: TwoTypeOption<Command, CodeAction>

    var isQuickFix: Bool { kind?.hasPrefix("quickfix") ?? false }
}

extension WorkspaceEdit {
    /// The text edits by document URI. File creations, renames and deletions are not carried out (yet).
    var textChanges: [String: [TextChange]] {
        var out: [String: [TextChange]] = [:]
        for (uri, edits) in changes ?? [:] { out[uri, default: []] += edits.map(TextChange.init) }
        for change in documentChanges ?? [] {
            if case .textDocumentEdit(let edit) = change {
                out[edit.textDocument.uri, default: []] += edit.edits.map(TextChange.init)
            }
        }
        return out
    }
}

extension TextChange {
    init(_ edit: TextEdit) {
        self.init(
            start: (edit.range.start.line, edit.range.start.character),
            end: (edit.range.end.line, edit.range.end.character), newText: edit.newText)
    }
}
