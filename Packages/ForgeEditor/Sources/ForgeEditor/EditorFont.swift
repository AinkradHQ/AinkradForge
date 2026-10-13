import AppKit

extension EditorOptions {
    /// The code face: `fontFamily` (the theme's mono, JetBrains Mono) at `fontSize`, else the system mono.
    var font: NSFont {
        fontFamily.flatMap { NSFont(name: $0, size: fontSize) } ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    /// Rows 1.62 em tall (the mockups' `line-height`), whatever the face's own line height.
    static func lineHeightMultiple(for font: NSFont) -> Double {
        let natural = font.ascender - font.descender + font.leading
        return natural > 0 ? 1.62 * font.pointSize / natural : 1.45
    }
}
