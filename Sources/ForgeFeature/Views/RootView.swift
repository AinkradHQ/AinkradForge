import AinkradAppKit
import SwiftUI

/// The window: welcome, or sidebar + editor area side by side on one surface.
struct RootView: View {
    @Bindable var model: ForgeModel
    let theme: HostTheme
    /// What another app asked Forge to open (`host.apps.takePendingLaunch()`), read once at first appearance.
    var takeLaunch: () -> String? = { nil }
    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        Group {
            if let workspace = model.workspace {
                GeometryReader { window in
                    HStack(spacing: 0) {
                        // 300 pt, giving way in a narrow window down to 280 (the tab picker's width) so the editor
                        // keeps its room (E1D1 FD28).
                        Sidebar(
                            model: model, workspace: workspace,
                            width: min(skin.size.s300, max(skin.size.s280, window.size.width * 0.3)))
                        EditorArea(model: model, workspace: workspace, palette: theme.terminalPalette)
                    }
                }
            } else {
                WelcomeView(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.tokens.background)
        .foregroundStyle(theme.tokens.foreground)
        .background { ShortcutLayer(model: model) }
        .overlay {
            if let start = model.palette { Palette(model: model, start: start) }
        }
        .ainkradModal(
            isPresented: Binding(get: { model.pendingClose != nil }, set: { if !$0 { model.resolvePendingClose(save: nil) } }),
            contentWidth: UnsavedDialog.width
        ) {
            UnsavedDialog(
                title: "Save changes to \((model.pendingClose.map { ($0 as NSString).lastPathComponent }) ?? "this file")?",
                message: "Your changes are lost if you don't save them.",
                saveTitle: "Save", resolve: model.resolvePendingClose(save:))
        }
        .ainkradModal(
            isPresented: Binding(get: { model.pendingLeave != nil }, set: { if !$0 { model.resolvePendingLeave(saveAll: nil) } }),
            contentWidth: UnsavedDialog.width
        ) {
            UnsavedDialog(
                title: "Save changes before leaving this workspace?",
                message: "\(model.unsavedPaths.count) file(s) have unsaved changes: \(model.unsavedPaths.joined(separator: ", "))",
                saveTitle: "Save All", resolve: model.resolvePendingLeave(saveAll:))
        }
        .ainkradConfirmDialog(
            isPresented: Binding(get: { model.search.confirmingReplaceAll }, set: { model.search.confirmingReplaceAll = $0 }),
            title: "Replace \(model.search.lineCount == SearchModel.cap ? "\(SearchModel.cap)+" : "\(model.search.lineCount)") lines in \(model.search.results.count) files?",
            message: "Open files change in their tabs and stay unsaved until ⌘S; the others are written now. Unticked preview changes are left as they are.",
            confirmTitle: "Replace All"
        ) { model.replaceAll() }
        .ainkradConfirmDialog(
            isPresented: Binding(
                get: { model.terminals.confirmingClose != nil }, set: { if !$0 { model.terminals.confirmingClose = nil } }),
            title: "End this terminal?",
            message: "Something is still running in it. Closing the terminal stops it.",
            confirmTitle: "End Terminal"
        ) { if let id = model.terminals.confirmingClose { model.terminals.close(id) } }
        .ainkradConfirmDialog(
            isPresented: Binding(
                get: { model.terminals.confirmingLeave != nil }, set: { if !$0 { model.terminals.confirmingLeave = nil } }),
            title: "End running terminals?",
            message: "Still running: \(model.terminals.confirmingLeave?.busy.joined(separator: ", ") ?? ""). Leaving the workspace stops them.",
            confirmTitle: "End and Leave"
        ) {
            let leave = model.terminals.confirmingLeave?.leave
            model.terminals.confirmingLeave = nil
            leave?()
        }
        .background { NoticeToaster(model: model) }
        .ainkradToastHost()
        .ainkradHostTheme(theme)
        .task { await model.start(launch: takeLaunch()) }
    }
}

/// Save / Don't Save / Cancel.
private struct UnsavedDialog: View {
    static let width: CGFloat = 420
    let title: String
    let message: String
    let saveTitle: String
    let resolve: (Bool?) -> Void
    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        VStack(alignment: .leading, spacing: skin.size.s12) {
            Text(title).font(skin.font(AinkradFontToken(sizeKey: "t15", weight: "semibold")))
            Text(message)
                .font(skin.font(AinkradFontToken(sizeKey: "t12")))
                .foregroundStyle(skin.color(skin.text.muted))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: skin.size.s8) {
                AinkradButton(title: "Don't Save", style: .secondary) { resolve(false) }.fixedSize()
                Spacer(minLength: skin.size.s8)
                AinkradButton(title: "Cancel", style: .secondary) { resolve(nil) }.fixedSize()
                    .keyboardShortcut(.cancelAction)
                AinkradButton(title: saveTitle, style: .primary) { resolve(true) }.fixedSize()
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(skin.size.s20)
    }
}

/// Shows `model.notice` (a failed save, an app that would not open) as a toast. A child view, because the toast centre lives inside `ainkradToastHost()`.
private struct NoticeToaster: View {
    let model: ForgeModel
    @Environment(\.ainkradToastCenter) private var toasts

    var body: some View {
        Color.clear.onChange(of: model.notice) { _, error in
            guard let error else { return }
            toasts.show(error, status: .danger, duration: 6)
            model.notice = nil
        }
    }
}

/// Binds every `ForgeCommand` with a shortcut. Zero-sized key-equivalent claims, not controls — SwiftUI has no
/// other way without a menu bar. Only available commands are mounted: a mounted chord is claimed even when
/// it would do nothing, and would take the key from the editor.
private struct ShortcutLayer: View {
    let model: ForgeModel
    @Environment(\.ainkradPaneIsFocused) private var isFocused

    var body: some View {
        ZStack {
            // Only the focused pane claims keys: an unfocused one would take the
            // chord from the pane you are working in, or from the host (FD36).
            if isFocused {
                ForEach(model.availableCommands.filter { $0.shortcut != nil }) { command in
                    if let shortcut = command.shortcut {
                        Button(command.title) { model.run(command) }  // design-lint: allow raw-control key-equivalent claim
                            .keyboardShortcut(KeyEquivalent(shortcut.key), modifiers: shortcut.modifiers)
                    }
                }
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}
