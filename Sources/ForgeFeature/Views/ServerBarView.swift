import AinkradAppKit
import ForgeLanguage
import SwiftUI

/// The language-server bar under the breadcrumb (E6, screen 19 B and D). A hint is a quiet fill (a capsule under
/// Glass); a stopped server's bar is washed red. Told apart by fill, never by a line.
/// In a narrow pane (a split) the actions move under the message and keep only the essential ones — Show Log
/// stays in the status bar's server menu, Set server path… in the bar and the palette — so the bar never widens the pane.
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
            // Set server path… stays at every width (FD48); "Not for …" gives way first when the row runs out.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: skin.size.s10) { setPath; notFor; hide }
                HStack(spacing: skin.size.s10) { setPath; hide }
            }
            .layoutPriority(1)
        case .stopped:
            if let spec = bar.spec {
                if !compact {
                    AinkradButton(title: "Show Log", style: .ghost) { model.showServerLog(spec.id) }.borderless().secondaryAccent().fixedSize()
                }
                AinkradButton(title: "Restart Server", style: .primary) { model.languages.restart(spec.id) }.fixedSize()
            }
        }
    }

    /// Forge's own server: where it is. No server for the language (FP112): any stdio LSP and its arguments.
    private var setPath: some View {
        AinkradButton(title: "Set server path…", style: .secondary) { model.chooseServerPath(forFileAt: bar.path) }
            .secondaryAccent()
            .fixedSize()
    }

    private var notFor: some View {
        AinkradButton(title: "Not for \(bar.language)", style: .ghost) { model.dismissServerHint(bar.language, forever: true) }
            .borderless()
            .secondaryAccent()
            .fixedSize()
    }

    private var hide: some View {
        RowAction(glyph: "✕", help: "Hide for this session") { model.dismissServerHint(bar.language, forever: false) }
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
    let model: ForgeModel
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        // The keys are the user's (⌘K rebinds them), so a hint never names a chord that no longer works.
        let hints: [(ForgeCommand, String)] = [(.quickOpen, "open a file"), (.commandPalette, "commands"), (.switchWorkspace, "switch workspace")]
        AinkradEmptyState(
            icon: "hammer",
            keyHints: hints.compactMap { command, label in
                model.shortcut(for: command).map { AinkradEmptyState.KeyHint(keys: $0.display, label: label) }
            }
        )
        .glyph("⚒")
        .glyphSize(34)
        .iconTint(theme.accentSecondary.opacity(skin.opacity.o50))
    }
}

/// A sidebar tab's empty state (mockup 19 A, B): the kit's compact glyph, title and message, then its actions — side
/// by side when they fit the sidebar, else stacked — both in the mockups' small outlined style, not a primary.
struct SidebarEmptyState<Actions: View>: View {
    let icon: String
    /// The mockup's text glyph (`▤`, `⑂`) in place of the symbol: 26 pt, the cyan accent at 70 % (`.sempty .glyph`).
    var glyph: String?
    let title: String
    let message: String
    @ViewBuilder let actions: Actions
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            state
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: skin.size.s8) { actions }
                VStack(spacing: skin.size.s8) { actions }
            }
            // The compact state keeps its own 40 pt foot; the actions sit 12 pt under its message (`.sempty`'s gap + 4).
            .padding(.top, skin.size.s12 - skin.size.s40)
        }
        .padding(.bottom, skin.size.s40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var state: AinkradEmptyState {
        let state = AinkradEmptyState(icon: icon, title: title, message: message).compact()
        guard let glyph else { return state }
        return state.glyph(glyph).iconTint(theme.accentSecondary.opacity(skin.opacity.o70))
    }
}
