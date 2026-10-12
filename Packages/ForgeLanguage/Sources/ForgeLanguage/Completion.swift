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
    /// What to select in `insertText` once written (UTF-16): a snippet's first placeholder; nil leaves the caret
    /// after it.
    public let selection: NSRange?
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
    /// A snippet as plain text, plus where the caret goes after inserting it: the first tab stop (`$1`, else `$0`),
    /// selecting its default text — `${1:date}` → `date`, selected. Choices take their first option, variables
    /// their default, `\$` is a `$`. Placeholders are not tabbable yet; this only lands the caret where typing
    /// starts. `selection` is a UTF-16 range in `text`; nil means the end.
    static func parse(_ snippet: String) -> (text: String, selection: NSRange?) {
        var text = ""
        var stops: [Int: NSRange] = [:]
        var chars = Substring(snippet)
        read(&chars, into: &text, stops: &stops, until: nil)
        let first = stops.keys.filter { $0 > 0 }.min() ?? (stops[0] == nil ? nil : 0)
        return (text, first.flatMap { stops[$0] })
    }

    static func plain(_ snippet: String) -> String { parse(snippet).text }

    /// Reads up to `until` (consumed) or the end.
    private static func read(_ chars: inout Substring, into text: inout String, stops: inout [Int: NSRange], until: Character?) {
        while let c = chars.first {
            chars.removeFirst()
            if c == until { return }
            if c == "\\", let next = chars.first, "$}\\,|".contains(next) {
                text.append(chars.removeFirst())
            } else if c == "$", let next = chars.first, next.isNumber {
                let n = Int(String(chars.prefix { $0.isNumber }))!
                chars = chars.drop { $0.isNumber }
                stop(n, NSRange(location: text.utf16.count, length: 0), in: &stops)
            } else if c == "$", chars.first == "{" {
                chars.removeFirst()
                let name = String(chars.prefix { $0.isNumber || $0.isLetter || $0 == "_" })
                chars = chars.dropFirst(name.count)
                let start = text.utf16.count
                switch chars.first {
                case ":":
                    chars.removeFirst()
                    read(&chars, into: &text, stops: &stops, until: "}")
                case "|":
                    chars.removeFirst()
                    let options = chars.prefix { $0 != "|" }
                    text += options.split(separator: ",", omittingEmptySubsequences: false).first ?? ""
                    chars = chars.dropFirst(options.count)
                    chars = chars.drop { $0 != "}" }.dropFirst()
                default:
                    chars = chars.drop { $0 != "}" }.dropFirst()
                }
                if let n = Int(name) { stop(n, NSRange(location: start, length: text.utf16.count - start), in: &stops) }
            } else {
                text.append(c)
            }
        }
    }

    /// A stop's first appearance is where the caret goes; later mirrors of it don't move it.
    private static func stop(_ n: Int, _ range: NSRange, in stops: inout [Int: NSRange]) {
        if stops[n] == nil { stops[n] = range }
    }
}
