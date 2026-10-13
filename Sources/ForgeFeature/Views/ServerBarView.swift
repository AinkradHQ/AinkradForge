import AinkradAppKit
import ForgeLanguage
import SwiftUI

/// The language-server bar under the breadcrumb (E6, screen 19 B and D). A hint is a quiet fill (a capsule under
/// Glass); a stopped server's bar is washed red. Told apart by fill, never by a line.
/// In a narrow pane (a split) the actions move under the message and keep only the essential ones — Set Server
/// Path… and Show Log stay in the status bar's server menu — so the bar never widens the pane.
struct ServerBarView: View {
    let model: ForgeModel
    let bar: ServerBar
    @State private var isNarrow = false
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradStatusColors) private var status

    /// Below this the message and its actions no longer share a line.
    private static let oneLineWidth: CGFloat = 640

    var body: some View {
        Group {
            if isNarrow {
                VStack(alignment: .leading, spacing: skin.size.s4) {
                    HStack(alignment: .firstTextBaseline, spacing: skin.size.s10) { icon; message }
                    HStack(spacing: skin.size.s10) {
                        Spacer(minLength: 0)
                        actions(compact: true)
                    }
                }
            } else {
                HStack(spacing: skin.size.s10) {
                    icon
                    message
                    Spacer(minLength: skin.size.s4)
                    actions(compact: false)
                }
            }
        }
        .font(skin.font(AinkradFontToken(size: 11.5)))
        .padding(.vertical, skin.size.s6)
        .padding(.horizontal, skin.size.s10)
        // Sized by the pane, never by its content: the width decides the layout.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .background(background)
        .onGeometryChange(for: Bool.self) { $0.size.width < Self.oneLineWidth } action: { isNarrow = $0 }
    }

    private var icon: some View {
        Image(systemName: bar.kind == .stopped ? "xmark.circle" : "info.circle")
            .foregroundStyle(bar.kind == .stopped ? status.danger : status.warning)
    }

    /// The message, the language's name in bold (mockup 19 B: "No language server for **Ruby** — …").
    private var message: some View {
        var text = AttributedString(bar.message)
        if let range = text.range(of: bar.language) {
            text[range].font = skin.font(AinkradFontToken(size: 11.5, weight: "semibold"))
            text[range].foregroundColor = theme.foreground
        }
        return Text(text)
            .foregroundStyle(skin.color(skin.text.muted))
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func actions(compact: Bool) -> some View {
        switch bar.kind {
        case .missing:
            if let spec = bar.spec, !compact {
                AinkradButton(title: "Set Server Path…", style: .secondary) {
                    if let path = ServerPathPicker.choose(spec) { model.setServerPath(spec.id, path) }
                }
                .secondaryAccent()
                .fixedSize()
            }
            AinkradButton(title: "Not for \(bar.language)", style: .ghost) {
                model.dismissServerHint(bar.language, forever: true)
            }
            .borderless()
            .secondaryAccent()
            .fixedSize()
            RowAction(glyph: "✕", help: "Hide for this session") { model.dismissServerHint(bar.language, forever: false) }
        case .stopped:
            if let spec = bar.spec {
                if !compact {
                    AinkradButton(title: "Show Log", style: .ghost) { model.showServerLog(spec.id) }.borderless().fixedSize()
                }
                AinkradButton(title: "Restart Server", style: .primary) { model.languages.restart(spec.id) }.fixedSize()
            }
        }
    }

    @ViewBuilder private var background: some View {
        let fill = bar.kind == .stopped ? status.danger.opacity(skin.opacity.o10) : theme.foreground.opacity(skin.opacity.o05)
        // A capsule only around one line; two lines (narrow) take the rounded rectangle.
        if skin.usesNativeGlass, !isNarrow {
            Capsule().fill(fill)
        } else {
            RoundedRectangle(cornerRadius: skin.size.s8, style: .continuous).fill(fill)
        }
    }
}

/// Asks for a language server's executable.
enum ServerPathPicker {
    @MainActor static func choose(_ spec: ServerSpec) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.message = "Choose the \(spec.command) executable for \(spec.language)."
        panel.prompt = "Use"
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

/// A server's indexing progress in the status bar (mockup 19 C): a thin 90 pt bar, the done part in the second
/// accent.
struct ProgressMeter: View {
    let fraction: Double
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        Capsule()
            .fill(theme.foreground.opacity(skin.opacity.o10))
            .frame(width: skin.size.s90, height: skin.size.s3)
            .overlay(alignment: .leading) {
                Capsule().fill(theme.accentSecondary).frame(width: skin.size.s90 * fraction, height: skin.size.s3)
            }
    }
}

/// The editor area with no file open in an empty folder (mockup 19 A): a faint ⚒ and the ways in, as keycaps.
struct EmptyEditorHints: View {
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        VStack(spacing: skin.size.s8) {
            Image(systemName: "hammer")
                .font(skin.font(AinkradFontToken(sizeKey: "t34")))
                .foregroundStyle(theme.accentSecondary.opacity(skin.opacity.o50))
            HStack(spacing: skin.size.s4) {
                hint("⌘P", "open a file ·")
                hint("⇧⌘P", "commands ·")
                hint("⌘O", "switch workspace")
            }
            .font(skin.font(AinkradFontToken(sizeKey: "t12")))
            .foregroundStyle(skin.color(skin.text.muted))
        }
        .padding(.bottom, skin.size.s40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func hint(_ keys: String, _ text: String) -> some View {
        HStack(spacing: skin.size.s4) {
            AinkradKbd(keys).outlined()
            Text(text)
        }
    }
}

/// A sidebar tab's empty state (mockup 19 A, B): the kit's glyph, title and message, then its actions — side by
/// side when they fit the sidebar, else stacked — both in the mockups' outlined style, not a primary.
struct SidebarEmptyState<Actions: View>: View {
    let icon: String
    let title: String
    let message: String
    @ViewBuilder let actions: Actions
    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        VStack(spacing: 0) {
            AinkradEmptyState(icon: icon, title: title, message: message)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: skin.size.s8) { actions }
                VStack(spacing: skin.size.s8) { actions }
            }
            .padding(.top, -skin.size.s16)
        }
        .padding(.bottom, skin.size.s40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
