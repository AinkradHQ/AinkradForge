import AinkradAppKit
import SwiftUI

/// The window: welcome, or sidebar + editor area side by side on one surface.
struct RootView: View {
    @Bindable var model: ForgeModel
    let theme: HostTheme
    /// What another app asked Forge to open (`host.apps.takePendingLaunch()`), read once at first appearance.
    var takeLaunch: () -> String? = { nil }
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradReduceMotion) private var reduceMotion

    /// Below this the sidebar would leave the editor too little room: it starts hidden.
    static let narrowWidth: CGFloat = 700

    var body: some View {
        Group {
            if let workspace = model.workspace {
                GeometryReader { window in
                    HStack(spacing: 0) {
                        // 280 pt (`.sidebar`); below `narrowWidth` (apps tiled three up) it hides until ⌘0 brings
                        // it back (E1D2 FD41).
                        // From the window's own width (not the model's copy of it): a narrow window opens without
                        // the sidebar instead of sliding it away.
                        if model.sidebarShown ?? (window.size.width >= Self.narrowWidth) {
                            Sidebar(model: model, workspace: workspace, width: skin.size.s280)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                        }
                        EditorArea(model: model, workspace: workspace, palette: theme.terminalPalette)
                    }
                    // Only a toggle slides it; a resize just reflows.
                    .animation(reduceMotion ? nil : skin.animation(skin.motion.present), value: model.sidebarShown)
                    .onGeometryChange(for: Bool.self) { $0.size.width < Self.narrowWidth } action: { model.windowIsNarrow = $0 }
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
        // Keycaps read ⌘⇧P, as the mockups write them (⇧⌘B and ⇧⌘M flip with it; ⌥⌘ and ⌃⌘ keep Apple's order).
        .ainkradCommandFirstKeys()
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
    @State private var chord = NextKey()

    var body: some View {
        let available = model.availableCommands
        ZStack {
            // Only the focused pane claims keys: an unfocused one would take the
            // chord from the pane you are working in, or from the host (FD36).
            if isFocused {
                ForEach(available.filter { model.shortcut(for: $0).map { !$0.afterCommandK } ?? false }) { command in
                    if let shortcut = model.shortcut(for: command) {
                        Button(command.title) { model.run(command) }  // design-lint: allow raw-control key-equivalent claim
                            .keyboardShortcut(KeyEquivalent(shortcut.key), modifiers: shortcut.modifiers)
                    }
                }
                // ⌘K starts a two-step chord (⌘K ⌘\ splits down) — claimed only while one can run and the palette
                // (whose ⌘K rebinds) is closed. The next key press finishes it, or is dropped.
                if model.palette == nil, available.contains(where: { model.shortcut(for: $0)?.afterCommandK == true }) {
                    Button("Chord") {  // design-lint: allow raw-control key-equivalent claim
                        model.awaitingChord = true
                        chord.listen { event in
                            model.awaitingChord = false
                            let second = Shortcut(event: event, afterCommandK: true)
                            if let command = model.availableCommands.first(where: { second != nil && model.shortcut(for: $0) == second }) {
                                model.run(command)
                            }
                            return true
                        }
                    }
                    .keyboardShortcut("k", modifiers: .command)
                }
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}
