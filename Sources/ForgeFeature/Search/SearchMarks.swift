import AppKit
import ForgeEditor

extension ForgeModel {
    /// While the Search tab holds a query: every match in `text` (the open file), as editor washes (mockup 07,
    /// FP53). Matched against the buffer itself, so the marks follow edits without a re-run.
    /// ponytail: re-matched on every editor update, capped at 2,000 marks and skipped past 1 MB of text.
    func searchMarks(in text: String, color: NSColor) -> [EditorMark] {
        guard sideTab == .search, !search.isReplaceOpen, (text as NSString).length < 1_000_000,
            let regex = try? search.query.compile()
        else { return [] }
        if case .references = search.status { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).prefix(SearchModel.cap)
            .compactMap { $0.range.length > 0 ? EditorMark(range: $0.range, color: color, isWash: true) : nil }
    }
}
