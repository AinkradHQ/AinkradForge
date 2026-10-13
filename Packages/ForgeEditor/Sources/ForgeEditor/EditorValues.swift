import AppKit

/// The user's editor settings.
public struct EditorOptions: Equatable, Sendable {
    public var fontSize: Double
    /// The code face's family (the theme's mono, JetBrains Mono); the system mono when it is not installed.
    public var fontFamily: String?
    public var tabWidth: Int
    /// Tab inserts spaces (`tabWidth` of them) rather than a tab character.
    public var insertSpaces: Bool
    public var wrapLines: Bool
    public var showMinimap: Bool
    public var showInvisibles: Bool

    public init(
        fontSize: Double = 13, tabWidth: Int = 4, insertSpaces: Bool = true, wrapLines: Bool = false,
        showMinimap: Bool = false, showInvisibles: Bool = false
    ) {
        self.fontSize = fontSize
        self.tabWidth = tabWidth
        self.insertSpaces = insertSpaces
        self.wrapLines = wrapLines
        self.showMinimap = showMinimap
        self.showInvisibles = showInvisibles
    }
}

/// A range of the buffer to mark: underlined (a diagnostic, in its severity's colour), washed (a search match —
/// a soft fill behind its text), or line-washed (a change made outside Forge — its lines filled edge to edge).
public struct EditorMark: Equatable, Sendable {
    public let range: NSRange
    public let color: NSColor
    public let isWash: Bool
    /// Wash every line the range touches across the editor's full width, not just the text.
    public let isLineWash: Bool

    public init(range: NSRange, color: NSColor, isWash: Bool = false, isLineWash: Bool = false) {
        self.range = range
        self.color = color
        self.isWash = isWash
        self.isLineWash = isLineWash
    }
}
