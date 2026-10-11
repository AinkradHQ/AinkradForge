import Foundation

/// One completion the server offers, as Forge shows and inserts it.
public struct Completion: Sendable {
    @frozen public enum Kind: Sendable {
        case method, function, property, variable, type, keyword, snippet, module, constant, other
    }

    public let label: String
    public let kind: Kind
    /// The type or signature, shown beside the label.
    public let detail: String?
    public let documentation: String?
    /// What accepting it writes (snippet placeholders already reduced to their default text).
    public let insertText: String
    public let filterText: String
    public let sortText: String
    /// Where the text it replaces starts, when the server says (0-based line, UTF-16 character); else the word
    /// before the caret is replaced.
    public let replaceStart: (line: Int, character: Int)?
    public let deprecated: Bool
}

/// The call the caret is in: its signature, and which parameter is being typed.
public struct SignatureHint: Equatable, Sendable {
    public let label: String
    /// The active parameter, as a UTF-16 range of `label`.
    public let activeParameter: NSRange?
    public let documentation: String?
}

enum Snippet {
    /// `${1:date}` → `date`, `$1` / `$0` → nothing, `\$` → `$`: placeholders are not tabbable yet, so they become
    /// their defaults.
    static func plain(_ snippet: String) -> String {
        var text = snippet
        while let range = text.range(of: #"\$\{\d+:([^{}]*)\}"#, options: .regularExpression) {
            let inner = text[range].dropFirst(2).drop { $0 != ":" }.dropFirst().dropLast()
            text.replaceSubrange(range, with: inner)
        }
        text = text.replacingOccurrences(of: #"\$\{\d+\}|\$\d+"#, with: "", options: .regularExpression)
        return text.replacingOccurrences(of: #"\$"#, with: "$")
    }
}
