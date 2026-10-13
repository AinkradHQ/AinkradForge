import AinkradAppKit
import SwiftUI

/// A result file: ▾, its icon, name and folder, the count pill — and on hover ⇄ while Replace is open, else ✕ to
/// dismiss it (mockup 07/08 `.hfile`). The Issues tab uses it too (with neither).
struct ResultFileRow: View {
    let path: String
    let count: Int
    let isFolded: Bool
    let isSelected: Bool
    /// Replace in this file (only while Replace is open).
    let onReplace: (() -> Void)?
    /// Drop the file from the results.
    var onDismiss: (() -> Void)?
    let toggle: () -> Void
    @State private var isHovered = false
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        // A plain button, so Full Keyboard Access can reach it and Space folds it (E1D1 FD34).
        Button(action: toggle) { label }  // design-lint: allow raw-control keyboard-reachable row (kit has no row button)
            .buttonStyle(.plain)
            .help(path)
            .rowActionKeys(action)
    }

    /// The row's ⇄ or ✕, also run from the keyboard when the row has focus.
    private var action: RowAction? {
        if let onReplace { return RowAction(glyph: "⇄", help: "Replace in this file (⇧↵)", action: onReplace) }
        return onDismiss.map { RowAction(glyph: "✕", help: "Dismiss this file's results (⌫)", action: $0) }
    }

    private var label: some View {
        let name = (path as NSString).lastPathComponent
        return HStack(spacing: skin.size.s6) {
            Text(isFolded ? "▸" : "▾")
                .font(skin.font(AinkradFontToken(sizeKey: "t11")))
                .foregroundStyle(skin.color(skin.text.faint))
                .frame(width: skin.size.s10)
            FileGlyph(name: name)
            Text(name)
                .font(skin.font(AinkradFontToken(sizeKey: "t12")))
                .foregroundStyle(theme.foreground)
                .lineLimit(1)
                .layoutPriority(1)
            Text((path as NSString).deletingLastPathComponent)
                .font(skin.font(AinkradFontToken(sizeKey: "t10_5")))
                .foregroundStyle(skin.color(skin.text.faint))
                .lineLimit(1)
            Spacer(minLength: skin.size.s4)
            CountPill(count: count)
            if let action { action.opacity(isHovered ? 1 : 0) }
        }
        .padding(.vertical, skin.size.s5)
        .padding(.horizontal, skin.size.s8)
        .ainkradRowBackground(isSelected: isSelected, isHovered: isHovered, style: .fill)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

/// The mockups' `.cnt`: a mono count on a round fill.
struct CountPill: View {
    let count: Int
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        Text("\(count)")
            .font(skin.font(AinkradFontToken(sizeKey: "t10", mono: "system")))
            .foregroundStyle(skin.color(skin.text.muted))
            .padding(.horizontal, skin.size.s6)
            .background(Capsule().fill(theme.surface.opacity(skin.opacity.o60)))
            .fixedSize()
    }
}

/// A row's faint text action (`.act`: ⇄, ✕). Nested in its row's button, so Full Keyboard Access can't reach
/// it: the focused row runs it from the keyboard instead (FD46) — ⌫ for ✕, ⇧↵ for ⇄ — and VoiceOver lists it
/// as the row's action.
struct RowAction: View {
    let glyph: String
    let help: String
    let action: () -> Void
    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        Button(action: action) {  // design-lint: allow raw-control row text action (mockup .act; kit icon buttons are boxed)
            Text(glyph)
                .font(skin.font(AinkradFontToken(sizeKey: "t11")))
                .foregroundStyle(skin.color(skin.text.faint))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Whether a focused row runs it on this key: ⌫ dismisses, ⇧↵ replaces now (as ⇧↵ renames now).
    func runs(on key: KeyEquivalent, modifiers: EventModifiers) -> Bool {
        let modifiers = modifiers.intersection([.command, .option, .control, .shift])
        switch glyph {
        case "✕": return key == .delete && modifiers.isEmpty
        case "⇄": return key == .return && modifiers == .shift
        default: return false
        }
    }
}

extension View {
    /// Runs a row's ⇄ / ✕ from the keyboard while the row has focus, and names it to VoiceOver (FD46).
    @ViewBuilder func rowActionKeys(_ action: RowAction?) -> some View {
        if let action {
            onKeyPress(phases: .down) { press in
                guard action.runs(on: press.key, modifiers: press.modifiers) else { return .ignored }
                action.action()
                return .handled
            }
            .accessibilityAction(named: action.help, action.action)
        } else {
            self
        }
    }
}

struct ResultLineRow: View {
    let match: LineMatch
    let isSelected: Bool
    /// While Replace is open: each match is shown struck through, followed by what it becomes.
    let replacement: ((String, NSRange) -> String)?
    /// The row's `.act`, shown on hover or selection: ⇄ replace this one while Replace is open, else ✕ dismiss.
    var action: RowAction?
    let onClick: () -> Void
    let onDoubleClick: () -> Void
    @State private var isHovered = false
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradStatusColors) private var status

    var body: some View {
        // A plain button, so Full Keyboard Access can reach the match and Space opens it (E1D1 FD34).
        Button(action: onClick) { label }  // design-lint: allow raw-control keyboard-reachable row (kit has no row button)
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture(count: 2).onEnded(onDoubleClick))
            .rowActionKeys(action)
    }

    private var label: some View {
        HStack(alignment: .firstTextBaseline, spacing: skin.size.s8) {
            Text("\(match.line)")
                .foregroundStyle(skin.color(skin.text.faint))
                .frame(minWidth: skin.size.s18, alignment: .trailing)
            Text(highlighted)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let action { action.opacity(isHovered || isSelected ? 1 : 0) }
        }
        .font(skin.font(AinkradFontToken(size: 11.5, mono: "system")))
        .padding(.vertical, skin.size.s3)
        .padding(.leading, skin.size.s26)
        .padding(.trailing, skin.size.s8)
        .ainkradRowBackground(isSelected: isSelected, isHovered: isHovered, style: .fill)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    /// The line from its first match onwards (leading indentation dropped), matches on a warm wash.
    private var highlighted: AttributedString {
        let ns = match.text as NSString
        let start = min(match.ranges.first?.location ?? 0, max(0, ns.length))
        // From the end of the indentation, or 24 characters before the first match — whichever is later.
        let indent = ns.substring(to: start).prefix { $0 == " " || $0 == "\t" }.utf16.count
        let from = max(indent, start - 24)
        var out = AttributedString()
        var cursor = from
        for range in match.ranges where range.location >= cursor {
            out += plain(ns.substring(with: NSRange(location: cursor, length: range.location - cursor)))
            var hit = AttributedString(ns.substring(with: range))
            if let replacement {
                hit.foregroundColor = status.danger
                hit.strikethroughStyle = .single
                hit.backgroundColor = status.danger.opacity(skin.opacity.o22)
                var new = AttributedString(replacement(match.text, range))
                new.foregroundColor = status.success
                new.backgroundColor = status.success.opacity(skin.opacity.o22)
                out += hit
                out += new
            } else {
                hit.foregroundColor = theme.foreground
                hit.backgroundColor = status.warning.opacity(skin.opacity.o28)
                out += hit
            }
            cursor = range.location + range.length
        }
        out += plain(ns.substring(from: min(cursor, ns.length)))
        return out
    }

    private func plain(_ text: String) -> AttributedString {
        var part = AttributedString(text.replacingOccurrences(of: "\t", with: " "))
        part.foregroundColor = isSelected ? theme.foreground : skin.color(skin.text.muted)
        return part
    }
}
