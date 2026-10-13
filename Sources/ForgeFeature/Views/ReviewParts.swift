import AinkradAppKit
import SwiftUI

/// A reviewed file's row (mockups 16 and 18 `.file` / `.rv-file`): ◆ name, folder (or "new file" / "deleted"),
/// then +added −removed at the end. A plain button: a click — or Space under Full Keyboard Access — shows or hides
/// its diff.
struct ReviewFileRow: View {
    let path: String
    /// "new file", "deleted"; else the folder ("·" at the root).
    let note: String?
    let added: Int
    let removed: Int
    let toggle: () -> Void
    @State private var isHovered = false
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradStatusColors) private var status

    var body: some View {
        let name = (path as NSString).lastPathComponent
        let folder = (path as NSString).deletingLastPathComponent
        Button(action: toggle) {  // design-lint: allow raw-control keyboard-reachable row (kit has no row button)
            HStack(spacing: skin.size.s8) {
                FileGlyph(name: name)
                Text(name)
                    .font(skin.font(AinkradFontToken(sizeKey: "t12")))
                    .foregroundStyle(theme.foreground)
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(note ?? (folder.isEmpty ? "·" : folder))
                    .font(skin.font(AinkradFontToken(sizeKey: "t11", mono: "system")))
                    .foregroundStyle(skin.color(skin.text.faint))
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: skin.size.s8)
                HStack(spacing: skin.size.s6) {
                    if added > 0 { Text("+\(added)").foregroundStyle(status.success) }
                    if removed > 0 { Text("−\(removed)").foregroundStyle(status.danger) }
                }
                .font(skin.font(AinkradFontToken(sizeKey: "t11", mono: "system", monospacedDigits: true)))
                .fixedSize()
            }
            .padding(.vertical, skin.size.s3)
            .padding(.horizontal, skin.size.s6)
            .background(
                RoundedRectangle(cornerRadius: skin.size.s6)
                    .fill(theme.foreground.opacity(isHovered ? skin.opacity.o05 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(path)
    }

    /// Added and removed lines in a diff.
    static func counts(_ diff: AinkradFileDiff) -> (added: Int, removed: Int) {
        let lines = diff.hunks.flatMap(\.lines)
        return (lines.filter { $0.kind == .insertion }.count, lines.filter { $0.kind == .deletion }.count)
    }
}

extension AinkradDiffReview {
    /// The review mockups' diff (16, 18): no header (the file row names the file), ✓ Keep / ↶ Undo ticks,
    /// editor-style lines with full-row washes, plain text (the mockups colour no syntax there).
    func reviewStyle() -> Self {
        hidesHeader().keepUndoHunkControls().editorLines()
    }
}

extension View {
    /// The review's surface (mockup `.rv`): 16 pt in, 14 pt from the sides and 12 below the tab row; square under
    /// Neon, rounded under Glass.
    func reviewSurface(_ skin: AinkradSkin, _ theme: HostThemeTokens) -> some View {
        padding(skin.size.s16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: skin.usesNativeGlass ? skin.size.s10 : 0)
                    .fill(theme.surface.opacity(skin.opacity.o45)))
            .padding(.horizontal, skin.size.s14)
            .padding(.top, skin.size.s12)
    }
}

/// "12 s ago", "6 min ago", "3 h ago" — the mockups' short relative times (15, 18).
enum ShortAgo {
    static func text(_ date: Date, now: Date = .now) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds) s ago" }
        if seconds < 3_600 { return "\(seconds / 60) min ago" }
        if seconds < 86_400 { return "\(seconds / 3_600) h ago" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
