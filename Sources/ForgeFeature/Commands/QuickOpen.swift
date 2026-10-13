import Foundation

/// ⌘P's ranking: the query's letters in order (a subsequence), preferring the file name over its folders,
/// word starts and camel humps (`sbrow` → **S**ide**b**ar**Row**), and runs of consecutive letters.
/// Recently opened files float up. Pure, so the ranking is asserted directly.
enum QuickOpen {
    struct Match: Equatable {
        let path: String
        let score: Int
    }

    static func rank(_ query: String, files: [String], recent: [String], limit: Int = 50) -> [Match] {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        let recency = Dictionary(recent.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        guard !needle.isEmpty else {
            // Nothing typed: recent files, newest first; with none yet, the workspace's files (E1D1 FD1).
            let recents = recent.filter(Set(files).contains)
            return (recents.isEmpty ? files : recents).prefix(limit).enumerated()
                .map { Match(path: $1, score: -$0) }
        }
        var matches: [Match] = []
        for path in files {
            guard var score = score(needle, in: path) else { continue }
            if let index = recency[path] { score += max(0, 40 - index * 4) }
            matches.append(Match(path: path, score: score))
        }
        return Array(
            matches.sorted { $0.score != $1.score ? $0.score > $1.score : $0.path.count < $1.path.count }.prefix(limit))
    }

    /// `nil` when the letters do not all appear in order.
    static func score(_ needle: [Character], in path: String) -> Int? {
        let slash = path.lastIndex(of: "/")
        let name = slash.map { String(path[path.index(after: $0)...]) } ?? path
        // The extension is not part of what you type for a file ("sbrow" must not match SidebarModel.s-w-ift).
        let stem = name.contains(".") && !name.hasPrefix(".") ? String(name[..<(name.lastIndex(of: ".") ?? name.endIndex)]) : name
        // A hit inside the file name is worth far more than one spread across folders.
        if let inName = subsequenceScore(needle, in: stem) { return 1_000 + inName - stem.count }
        if let inPath = subsequenceScore(needle, in: path) { return inPath - path.count / 4 }
        return nil
    }

    /// Greedy left-to-right match with bonuses for word starts, camel humps and consecutive letters.
    static func subsequenceScore(_ needle: [Character], in haystack: String) -> Int? {
        subsequence(needle, in: haystack)?.score
    }

    /// The offsets (in `Character`s) of the letters `query` matches in `text`, for drawing them bold; empty when
    /// it does not match.
    static func matchedOffsets(_ query: String, in text: String) -> [Int] {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return [] }
        return subsequence(needle, in: text)?.offsets ?? []
    }

    private static func subsequence(_ needle: [Character], in haystack: String) -> (score: Int, offsets: [Int])? {
        let chars = Array(haystack)
        var offsets: [Int] = []
        var score = 0
        var position = 0
        var previousMatch = -2
        for wanted in needle {
            let matches = { (index: Int) in Character(chars[index].lowercased()) == wanted }
            let rest = position..<chars.count
            // Continue a run if the next letter matches; else jump to the next word start that matches
            // (so `sr` takes the R of "Row", not the r inside "Sidebar"); else the next occurrence.
            let found: Int? =
                if position < chars.count, previousMatch == position - 1, matches(position) {
                    position
                } else {
                    rest.first { matches($0) && isWordStart(chars, $0) } ?? rest.first(where: matches)
                }
            guard let at = found else { return nil }
            score += 10
            if isWordStart(chars, at) { score += 25 }
            if at == previousMatch + 1 { score += 15 }
            if at == 0 { score += 20 }
            previousMatch = at
            position = at + 1
            offsets.append(at)
        }
        return (score, offsets)
    }

    private static func isWordStart(_ chars: [Character], _ index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = chars[index - 1]
        if "/._- ".contains(previous) { return true }
        return chars[index].isUppercase && previous.isLowercase
    }
}
