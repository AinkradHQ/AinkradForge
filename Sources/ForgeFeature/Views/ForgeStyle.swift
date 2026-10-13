import AinkradAppKit
import SwiftUI

/// The mockups' surface values (`Designs/forge/base.css` + `forge.css`) that the kit has no token for, built
/// from the theme's own colours. Neon and Liquid Glass differ; each helper says which CSS value it is.
@MainActor
enum ForgeStyle {
    /// `--fill`: the active tab, the selected sidebar tab. Neon: the elevated surface at 60 %; Glass: white at 6 %.
    static func fill(_ skin: AinkradSkin, _ theme: HostThemeTokens) -> Color {
        skin.usesNativeGlass ? skin.color(skin.palette.white).opacity(skin.opacity.o06) : theme.surfaceElevated.opacity(skin.opacity.o60)
    }

    /// `.pane`: an editor pane. Neon: the window background at 55 % (code reads as on the window); Glass: `--fill`.
    static func pane(_ skin: AinkradSkin, _ theme: HostThemeTokens) -> Color {
        skin.usesNativeGlass ? fill(skin, theme) : theme.background.opacity(skin.opacity.o55)
    }

    /// `--stroke`: Neon's cyan hairline (accent 2 at 45 %); Glass's foreground at 12 %.
    static func stroke(_ skin: AinkradSkin, _ theme: HostThemeTokens) -> Color {
        skin.usesNativeGlass ? theme.foreground.opacity(skin.opacity.o12) : theme.accentSecondary.opacity(skin.opacity.o45)
    }

    /// `--fill-strong`: a chamfered card's fill (the workspace card, the recents panel).
    static func fillStrong(_ skin: AinkradSkin, _ theme: HostThemeTokens) -> Color {
        theme.surfaceElevated.opacity(skin.usesNativeGlass ? skin.opacity.o72 : skin.opacity.o95)
    }

    /// The syntax and file-type hues the mockups set (forge.css `--syn-*`, `.ic.*`): theme data, as hex strings.
    static func hue(_ hex: String) -> Color {
        Color(nsColor: EditorPalette.color(hex: hex) ?? .labelColor)  // design-lint: allow raw-color mockup hue table (theme data)
    }
}

/// The file-type glyph the mockups draw before a name (tree, tabs, palette, breadcrumb): `◆` for code in its
/// language's hue, `≡` config, `▤` docs and folders, `·` anything else.
struct FileGlyph: View {
    let name: String
    var isDirectory = false
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        let (glyph, color) = Self.glyph(name, isDirectory: isDirectory)
        Text(glyph)
            .font(skin.font(AinkradFontToken(sizeKey: "t11")))
            .foregroundStyle(color.map(ForgeStyle.hue) ?? (isDirectory ? theme.accentSecondary : skin.color(skin.text.faint)))
            .frame(width: skin.size.s14)
    }

    /// The glyph and its hue (nil: the folder accent, or faint). Pure, so it is tested.
    static func glyph(_ name: String, isDirectory: Bool) -> (String, String?) {
        if isDirectory { return ("▤", nil) }
        switch (name as NSString).pathExtension.lowercased() {
        case "swift": return ("◆", "f97316")
        case "rb": return ("◆", "f87171")
        case "md", "markdown", "txt": return ("▤", "60a5fa")
        case "json", "yml", "yaml", "toml", "plist", "xml": return ("≡", "f472b6")
        default: return ("·", nil)
        }
    }
}
