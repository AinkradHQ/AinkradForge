import Foundation

/// LSP positions are (line, character) with characters counted in UTF-16 code units — the same unit as
/// `NSRange` — over the buffer as the server saw it (LF line breaks). Pure, so every edge is tested.
public struct LineIndex: Sendable {
    /// UTF-16 offset where each line starts.
    private let starts: [Int]
    private let length: Int

    public init(_ text: String) {
        var starts = [0]
        var offset = 0
        for unit in text.utf16 {
            offset += 1
            if unit == 10 { starts.append(offset) }
        }
        self.starts = starts
        self.length = offset
    }

    public var lineCount: Int { starts.count }

    /// The UTF-16 offset of a 0-based (line, character), clamped into the text.
    public func offset(line: Int, character: Int) -> Int {
        guard line < starts.count else { return length }
        let start = starts[max(0, line)]
        let end = line + 1 < starts.count ? starts[line + 1] - 1 : length
        return min(start + max(0, character), end)
    }

    /// The 0-based (line, character) of a UTF-16 offset.
    public func position(of offset: Int) -> (line: Int, character: Int) {
        let clamped = min(max(0, offset), length)
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= clamped { low = mid } else { high = mid - 1 }
        }
        return (low, clamped - starts[low])
    }

    public func range(from start: (line: Int, character: Int), to end: (line: Int, character: Int)) -> NSRange {
        let a = offset(line: start.line, character: start.character)
        let b = offset(line: end.line, character: end.character)
        return NSRange(location: min(a, b), length: abs(b - a))
    }
}
