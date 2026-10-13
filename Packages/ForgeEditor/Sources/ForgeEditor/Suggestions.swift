import AppKit
@preconcurrency internal import CodeEditSourceEditor
@preconcurrency internal import CodeEditTextView
import SwiftUI

/// A completion to offer. The caller maps its language server's items onto these.
public struct EditorSuggestion: Sendable {
    public enum Kind: Sendable {
        case method, function, property, variable, type, keyword, snippet, module, constant, other
    }

    public let label: String
    public let kind: Kind
    public let detail: String?
    public let documentation: String?
    public let insertText: String
    /// What to select in `insertText` once written (UTF-16): a snippet's first placeholder; nil leaves the caret
    /// after it.
    public let selection: NSRange?
    public let filterText: String
    /// The UTF-16 offset the replaced text starts at, when the server says; else the word before the caret.
    public let replaceStart: Int?
    public let deprecated: Bool

    public init(
        label: String, kind: Kind, detail: String?, documentation: String?, insertText: String, filterText: String,
        replaceStart: Int?, deprecated: Bool, selection: NSRange? = nil
    ) {
        self.label = label
        self.kind = kind
        self.detail = detail
        self.documentation = documentation
        self.insertText = insertText
        self.selection = selection
        self.filterText = filterText
        self.replaceStart = replaceStart
        self.deprecated = deprecated
    }

    /// The items for what has been typed of the word: those whose filter text starts with it first, then those
    /// that merely contain its letters in order; the server's order within each.
    static func filter(_ all: [EditorSuggestion], prefix: String) -> [EditorSuggestion] {
        guard !prefix.isEmpty else { return all }
        let needle = prefix.lowercased()
        var starts: [EditorSuggestion] = []
        var contains: [EditorSuggestion] = []
        for item in all {
            let hay = item.filterText.lowercased()
            if hay.hasPrefix(needle) {
                starts.append(item)
            } else if isSubsequence(needle, of: hay) {
                contains.append(item)
            }
        }
        return starts + contains
    }

    private static func isSubsequence(_ needle: String, of hay: String) -> Bool {
        var rest = needle[...]
        for character in hay where character == rest.first {
            rest = rest.dropFirst()
            if rest.isEmpty { return true }
        }
        return rest.isEmpty
    }
}

/// An identifier character, for finding the word being completed.
func isWordUnit(_ unit: unichar) -> Bool {
    unit == 95 || (UnicodeScalar(unit).map { CharacterSet.alphanumerics.contains($0) } ?? false)
}

/// What CodeEditSourceEditor's suggestion window lists.
struct SuggestionEntry: CodeSuggestionEntry {
    let suggestion: EditorSuggestion
    /// The editor's colours (nil only before it first appeared).
    let colors: EditorColors?

    var label: String { suggestion.label }
    var detail: String? { suggestion.detail }
    var documentation: String? { suggestion.documentation }
    var pathComponents: [String]? { nil }
    var targetPosition: CursorPosition? { nil }
    /// Only with documentation to go with it: a footer repeating the label is noise (FD5).
    var sourcePreview: String? { suggestion.documentation == nil ? nil : suggestion.label }
    var deprecated: Bool { suggestion.deprecated }

    /// A lettered badge per kind, as in the mockup: M method, F function, P property, V variable, T type…
    var image: Image {
        let letter =
            switch suggestion.kind {
            case .method: "m"
            case .function: "f"
            case .property: "p"
            case .variable: "v"
            case .type: "t"
            case .keyword: "k"
            case .snippet: "s"
            case .module: "folder"
            case .constant: "c"
            case .other: "circle"
            }
        return Image(systemName: letter.count == 1 ? "\(letter).square.fill" : "\(letter).fill")
    }

    var imageColor: Color {
        guard let colors else { return .secondary }
        let color: NSColor =
            switch suggestion.kind {
            case .method, .function: colors.commands
            case .property, .variable, .constant: colors.values
            case .type: colors.types
            case .keyword: colors.keywords
            case .snippet, .module, .other: colors.comments
            }
        return Color(nsColor: color)
    }
}

extension EditorHost.Coordinator: @preconcurrency CodeSuggestionDelegate {
    func completionTriggerCharacters() -> Set<String> { suggestionTriggers }

    func completionSuggestionsRequested(
        textView: TextViewController, cursorPosition: CursorPosition
    ) async -> (windowPosition: CursorPosition, items: [CodeSuggestionEntry])? {
        guard let suggest else { return nil }
        hover.dismiss()
        let caret = cursorPosition.range.location
        let text = textView.textView.textStorage.string as NSString
        guard let start = Self.completionStart(in: text, caret: caret, triggers: suggestionTriggers) else { return nil }
        let found = await suggest(caret)
        offered = found
        wordStart = start
        let items = EditorSuggestion.filter(found, prefix: text.substring(with: NSRange(location: start, length: caret - start)))
        guard !items.isEmpty else { return nil }
        return (CursorPosition(range: NSRange(location: start, length: 0)), items.map { SuggestionEntry(suggestion: $0, colors: colors) })
    }

    /// Where the word being completed starts, or nil when there is nothing to complete. Only inside a word or
    /// right after a trigger: whatever path asked, a completion at "(" (a signature trigger, not ours) crashes
    /// sourcekit-lsp after one at "." (E0 FD15). Never on a number: CodeEdit asks on digits, and Return after
    /// `times: 2` must break the line, not accept `Int32` (E0 FD22).
    static func completionStart(in text: NSString, caret: Int, triggers: Set<String>) -> Int? {
        var start = min(caret, text.length)
        while start > 0, isWordUnit(text.character(at: start - 1)) { start -= 1 }
        if start == caret, caret > 0, !triggers.contains(text.substring(with: NSRange(location: caret - 1, length: 1))) {
            return nil
        }
        if start < caret, UnicodeScalar(text.character(at: start)).map(CharacterSet.decimalDigits.contains) == true { return nil }
        return start
    }

    /// Typing narrows the list; leaving the word (a space, a bracket, moving back past its start) closes it.
    func completionOnCursorMove(textView: TextViewController, cursorPosition: CursorPosition) -> [CodeSuggestionEntry]? {
        let caret = cursorPosition.range.location
        let text = textView.textView.textStorage.string as NSString
        guard cursorPosition.range.length == 0, caret >= wordStart, caret <= text.length else { return nil }
        let typed = text.substring(with: NSRange(location: wordStart, length: caret - wordStart))
        guard typed.utf16.allSatisfy(isWordUnit) else { return nil }
        let items = EditorSuggestion.filter(offered, prefix: typed)
        return items.isEmpty ? nil : items.map { SuggestionEntry(suggestion: $0, colors: colors) }
    }

    func completionWindowApplyCompletion(item: CodeSuggestionEntry, textView: TextViewController, cursorPosition: CursorPosition?) {
        guard let entry = item as? SuggestionEntry,
            let caret = (cursorPosition ?? textView.cursorPositions.first)?.range.location
        else { return }
        let start = min(entry.suggestion.replaceStart ?? wordStart, caret)
        textView.textView.replaceCharacters(in: NSRange(location: start, length: caret - start), with: entry.suggestion.insertText)
        if let selection = entry.suggestion.selection {
            textView.textView.selectionManager.setSelectedRange(NSRange(location: start + selection.location, length: selection.length))
        }
    }

    func completionWindowDidClose() { offered = [] }
}

extension EditorHost.Coordinator {
    /// After a signature trigger was typed, or whenever the caret moves while the hint shows (the server then
    /// moves the active parameter along, or answers that the caret has left the call).
    func trackSignature(_ controller: TextViewController, _ positions: [CursorPosition]) {
        guard !signatureTriggers.isEmpty || signatureShown else { return }
        guard positions.count == 1, let caret = positions.first?.range, caret.length == 0 else {
            if signatureShown { onSignature(nil) }
            return
        }
        let text = controller.textView.textStorage.string as NSString
        let typed = caret.location > 0 && caret.location <= text.length
            ? text.substring(with: NSRange(location: caret.location - 1, length: 1)) : ""
        guard signatureShown || signatureTriggers.contains(typed) else { return }
        guard let frame = caretFrame(controller, caret.location) else { return }
        onSignature((caret.location, frame))
    }
}
