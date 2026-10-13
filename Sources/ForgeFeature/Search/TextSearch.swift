import Foundation

/// What to look for: the query and its toggles, compiled once into a regular expression.
struct SearchQuery: Equatable, Sendable {
    var text = ""
    var matchCase = false
    var wholeWord = false
    var regex = false

    /// `nil` for an empty query; throws a message for an invalid regular expression.
    func compile() throws -> NSRegularExpression? {
        guard !text.isEmpty else { return nil }
        var pattern = regex ? text : NSRegularExpression.escapedPattern(for: text)
        if wholeWord { pattern = "\\b(?:\(pattern))\\b" }
        do {
            return try NSRegularExpression(pattern: pattern, options: matchCase ? [] : [.caseInsensitive])
        } catch {
            throw FileOps.Failure(message: "Not a valid regular expression.")
        }
    }
}

/// One line that matched, with every match on it (UTF-16 ranges within `text`).
struct LineMatch: Equatable, Sendable, Identifiable {
    /// 1-based.
    let line: Int
    let text: String
    let ranges: [NSRange]
    var id: Int { line }
}

/// Search and replace over text. Pure, so every rule is asserted directly.
enum TextSearch {
    /// Every matching line of `text`. Lines longer than 2,000 characters are cut for display (matches past
    /// the cut still count, their range clamped), so a minified file cannot flood the list.
    static func matches(in text: String, regex: NSRegularExpression) -> [LineMatch] {
        var result: [LineMatch] = []
        var number = 0
        text.enumerateLines { line, _ in
            number += 1
            let ns = line as NSString
            let found = regex.matches(in: line, range: NSRange(location: 0, length: ns.length)).map(\.range)
                .filter { $0.length > 0 }
            guard !found.isEmpty else { return }
            let shown = ns.length > 2_000 ? ns.substring(to: 2_000) : line
            let limit = (shown as NSString).length
            result.append(LineMatch(line: number, text: shown, ranges: found.map {
                NSRange(location: min($0.location, limit), length: max(0, min($0.length, limit - min($0.location, limit))))
            }))
        }
        return result
    }

    /// `text` with every match replaced. With `regex`, `$1`… in `replacement` are capture groups; otherwise
    /// it is literal. `preserveCase` adapts the replacement to each match: ALL CAPS, Capitalised, lower.
    /// `lines`, when given, picks the matches to replace by the (1-based) line they start on.
    static func replace(
        in text: String, regex: NSRegularExpression, with replacement: String, isRegex: Bool, preserveCase: Bool,
        limit: Int? = nil, lines: ((Int) -> Bool)? = nil
    ) -> (text: String, count: Int) {
        let ns = text as NSString
        var found = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        if let lines {
            // Line starts in UTF-16 offsets, by the same rule as `matches(in:)`'s line numbers.
            var starts: [Int] = []
            ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines, .substringNotRequired]) {
                _, _, enclosing, _ in starts.append(enclosing.location)
            }
            var line = 0
            found = found.filter { match in
                while line + 1 < starts.count, starts[line + 1] <= match.range.location { line += 1 }
                return lines(line + 1)
            }
        }
        if let limit { found = Array(found.prefix(limit)) }
        guard !found.isEmpty else { return (text, 0) }
        let template = isRegex ? replacement : NSRegularExpression.escapedTemplate(for: replacement)
        let out = NSMutableString(string: text)
        for match in found.reversed() {
            var piece = regex.replacementString(for: match, in: text, offset: 0, template: template)
            if preserveCase { piece = adaptCase(piece, to: ns.substring(with: match.range)) }
            out.replaceCharacters(in: match.range, with: piece)
        }
        return (out as String, found.count)
    }

    /// Line `index` (0-based) of `text`, without its line break; "" past the end.
    static func line(_ index: Int, of text: String) -> String {
        var number = 0
        var found = ""
        text.enumerateLines { line, stop in
            if number == index {
                found = line
                stop = true
            }
            number += 1
        }
        return found
    }

    /// The identifier around UTF-16 `character` of `line` ("" when there is none).
    static func word(in line: String, at character: Int) -> String {
        let ns = line as NSString
        func isWord(_ index: Int) -> Bool {
            let unit = ns.character(at: index)
            return unit == 95 || (UnicodeScalar(unit).map { CharacterSet.alphanumerics.contains($0) } ?? false)
        }
        var start = min(max(0, character), ns.length)
        var end = start
        while start > 0, isWord(start - 1) { start -= 1 }
        while end < ns.length, isWord(end) { end += 1 }
        return ns.substring(with: NSRange(location: start, length: end - start))
    }

    /// isSelected → isActive stays; IsSelected → IsActive; ISSELECTED → ISACTIVE.
    static func adaptCase(_ replacement: String, to original: String) -> String {
        let letters = original.filter(\.isLetter)
        guard let first = letters.first else { return replacement }
        if letters.count > 1, letters.allSatisfy({ $0.isUppercase }) { return replacement.uppercased() }
        if first.isUppercase { return replacement.prefix(1).uppercased() + replacement.dropFirst() }
        if first.isLowercase { return replacement.prefix(1).lowercased() + replacement.dropFirst() }
        return replacement
    }
}

/// Include / exclude globs: `*` within a path segment, `**` across segments, `?` one character. A glob
/// without a `/` matches a file name anywhere (`*.swift`); a bare folder name matches everything under it.
struct GlobSet: Equatable, Sendable {
    private let patterns: [NSRegularExpression]
    let isEmpty: Bool

    /// Comma-separated globs, e.g. "Sources/**, Tests/**".
    init(_ list: String) {
        let globs = list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        patterns = globs.compactMap { try? NSRegularExpression(pattern: Self.regex(for: $0)) }
        isEmpty = patterns.isEmpty
    }

    func matches(_ path: String) -> Bool {
        let range = NSRange(location: 0, length: (path as NSString).length)
        return patterns.contains { $0.firstMatch(in: path, range: range) != nil }
    }

    static func regex(for glob: String) -> String {
        var glob = glob.hasPrefix("./") ? String(glob.dropFirst(2)) : glob
        if glob.hasSuffix("/") { glob += "**" }
        let anchored = glob.contains("/")
        var out = ""
        var chars = Array(glob)[...]
        while let c = chars.popFirst() {
            switch c {
            case "*":
                if chars.first == "*" {
                    chars.removeFirst()
                    if chars.first == "/" {
                        chars.removeFirst()
                        out += "(?:.*/)?"
                    } else {
                        out += ".*"
                    }
                } else {
                    out += "[^/]*"
                }
            case "?": out += "[^/]"
            default: out += NSRegularExpression.escapedPattern(for: String(c))
            }
        }
        // "Sources" also means everything inside it; an unanchored glob matches at any depth.
        return (anchored ? "^" : "(?:^|/)") + out + "(?:/.*)?$"
    }
}
