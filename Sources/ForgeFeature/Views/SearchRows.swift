import AinkradAppKit
import SwiftUI

/// A result file: ▾, its icon, name and folder, the count pill — and ⇄ on hover while Replace is open (mockup 07/08
/// `.hfile`). The Issues tab uses it too.
struct ResultFileRow: View {
    let path: String
    let count: Int
    let isFolded: Bool
    let isSelected: Bool
    /// Replace in this file (only while Replace is open).
    let onReplace: (() -> Void)?
    let toggle: () -> Void
    @State private var isHovered = false
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        // A plain button, so Full Keyboard Access can reach it and Space folds it (E1D1 FD34).
        Button(action: toggle) { label }  // design-lint: allow raw-control keyboard-reachable row (kit has no row button)
            .buttonStyle(.plain)
            .help(path)
    }

    private var label: some View {
        let name = (path as NSString).lastPathComponent
        return HStack(spacing: skin.size.s6) {
            Text(isFolded ? "▸" : "▾")
                .font(skin.font(AinkradFontToken(sizeKey: "t11")))
                .foregroundStyle(skin.color(skin.text.faint))
                .frame(width: skin.size.s10)
            Image(systemName: FileIcon.symbol(for: FileNode(path: path, name: name, isDirectory: false, children: [])))
                .font(skin.font(AinkradFontToken(sizeKey: "t11")))
                .foregroundStyle(FileIcon.tint(for: name, theme: theme) ?? skin.color(skin.text.faint))
                .frame(width: skin.size.s14)
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
            if let onReplace {
                RowAction(glyph: "⇄", help: "Replace in this file", action: onReplace).opacity(isHovered ? 1 : 0)
            }
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

/// A row's faint text action (`.act`: ⇄, ✕).
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
}

struct ResultLineRow: View {
    let match: LineMatch
    let isSelected: Bool
    /// While Replace is open: each match is shown struck through, followed by what it becomes.
    let replacement: ((String, NSRange) -> String)?
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
    }

    private var label: some View {
        HStack(alignment: .firstTextBaseline, spacing: skin.size.s8) {
            Text("\(match.line)")
                .foregroundStyle(skin.color(skin.text.faint))
                .frame(minWidth: skin.size.s18, alignment: .trailing)
            Text(highlighted)
                .lineLimit(1)
            Spacer(minLength: 0)
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

/// The query, replacement and glob fields (mockup 07/08 `.sfield`): mono text with its toggles inside — or, compact,
/// a faint `include` / `exclude` label before it — in the kit field's chrome; a glass capsule under Liquid Glass.
/// Local because the kit's fields have no trailing slot, and its labelled field is a size larger than `.small`.
struct SearchInputField<Trailing: View>: View {
    @Binding var text: String
    let placeholder: String
    var focus: FocusState<Bool>.Binding?
    var label: String?
    let trailing: Trailing
    @Environment(\.ainkradSkin) private var skin

    init(
        text: Binding<String>, placeholder: String, focus: FocusState<Bool>.Binding? = nil, label: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        _text = text
        self.placeholder = placeholder
        self.focus = focus
        self.label = label
        self.trailing = trailing()
    }

    private var compact: Bool { label != nil }

    var body: some View {
        let row = HStack(spacing: skin.size.s6) {
            if let label {
                Text(label)
                    .font(skin.font(AinkradFontToken(sizeKey: "t10")))
                    .foregroundStyle(skin.color(skin.text.faint))
                    .frame(width: skin.size.s46, alignment: .leading)
            }
            field
            trailing
        }
        if #available(macOS 26, *), skin.usesNativeGlass {
            row
                .padding(.horizontal, compact ? skin.size.s10 : AinkradSpacing.md)
                .padding(.vertical, compact ? skin.size.s4 : AinkradSpacing.sm)
                .glassEffect(.regular, in: .capsule)
        } else {
            let field = skin.roles.field
            let shape = AinkradSkinShape(token: field.shape)
            let state: AinkradControlState = focus?.wrappedValue == true ? [.focused] : []
            row
                .padding(.leading, compact ? skin.size.s8 : skin.size.s10)
                .padding(.trailing, skin.size.s8)
                .padding(.vertical, compact ? skin.size.s4 : skin.size.s6)
                .background(shape.fill(skin.color(field.fill)))
                .overlay(shape.strokeBorder(skin.color(field.stroke.color, state: state), lineWidth: field.stroke.width.resolve(state)))
                .shadow(color: skin.color(field.glow.color, state: state), radius: field.glow.radius.resolve(state))
        }
    }

    @ViewBuilder private var field: some View {
        let base = TextField(placeholder, text: $text)  // design-lint: allow raw-control kit fields have no trailing slot for the toggles
            .textFieldStyle(.plain)
            .font(skin.font(AinkradFontToken(sizeKey: compact ? "t11" : "t12", mono: "system")))
            .foregroundStyle(skin.color(skin.text.primary))
            .tint(skin.color(skin.palette.accentSecondary))
        if let focus { base.focused(focus) } else { base }
    }
}

extension SearchInputField where Trailing == EmptyView {
    /// A glob field: `include` / `exclude` before the text.
    init(text: Binding<String>, placeholder: String, label: String) {
        self.init(text: text, placeholder: placeholder, label: label) { EmptyView() }
    }
}

/// A toggle inside a search field (`.tg`): `Aa`, `⌶`, `✱`, `AB` — faint off, lit on.
struct InlineToggle: View {
    let title: String
    @Binding var isOn: Bool
    let help: String
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        Button { isOn.toggle() } label: {  // design-lint: allow raw-control in-field toggle (mockup .tg; kit toggles are full buttons)
            Text(title)
                .font(skin.font(AinkradFontToken(sizeKey: "t11", mono: "system")))
                .foregroundStyle(isOn ? theme.foreground : skin.color(skin.text.faint))
                .padding(.horizontal, skin.usesNativeGlass ? skin.size.s7 : skin.size.s5)
                .padding(.vertical, skin.usesNativeGlass ? skin.size.s2 : skin.size.s1)
                .background(shape.fill(isOn ? onFill : .clear))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var shape: AnyShape {
        skin.usesNativeGlass ? AnyShape(Capsule()) : AnyShape(RoundedRectangle(cornerRadius: skin.size.s4))
    }

    private var onFill: Color {
        skin.usesNativeGlass ? theme.foreground.opacity(skin.opacity.o22) : theme.accentPrimary.opacity(skin.opacity.o40)
    }
}

/// A labelled text field. Under Liquid Glass it is a glass capsule like the kit's search field (whose glass
/// path it mirrors); elsewhere the kit's text field. Local only because `AinkradTextField` draws Apple's flat
/// rounded field under Glass — a glass-capsule text field in the kit is the proposal.
struct GlassField: View {
    let label: String
    @Binding var text: String
    let placeholder: String
    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        if #available(macOS 26, *), skin.usesNativeGlass {
            HStack(spacing: AinkradSpacing.sm) {
                Text(label)
                    .font(skin.font(AinkradFontToken(sizeKey: "t11")))
                    .foregroundStyle(.secondary)
                TextField(placeholder, text: $text)  // design-lint: allow raw-control kit gap: glass capsule text field
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, AinkradSpacing.md)
            .padding(.vertical, AinkradSpacing.sm)
            .glassEffect(.regular, in: .capsule)
        } else {
            AinkradTextField(text: $text, placeholder: "\(label.capitalized): \(placeholder)")
        }
    }
}
