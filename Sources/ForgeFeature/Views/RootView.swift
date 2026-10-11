import AinkradAppKit
import SwiftUI

/// The window: welcome, or sidebar + editor area side by side on one surface.
struct RootView: View {
    @Bindable var model: ForgeModel
    let theme: HostTheme
    /// What another app asked Forge to open (`host.apps.takePendingLaunch()`), read once at first appearance.
    var takeLaunch: () -> String? = { nil }

    var body: some View {
        Group {
            if let workspace = model.workspace {
                HStack(spacing: 0) {
                    Sidebar(model: model, workspace: workspace)
                    EditorArea(model: model, workspace: workspace, palette: theme.terminalPalette)
                }
            } else {
                WelcomeView(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.tokens.background)
        .foregroundStyle(theme.tokens.foreground)
        .background { Shortcuts(model: model) }
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
        .background { SaveErrorToaster(model: model) }
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

/// Shows a failed save as a toast. A child view, because the toast centre lives inside `ainkradToastHost()`.
private struct SaveErrorToaster: View {
    let model: ForgeModel
    @Environment(\.ainkradToastCenter) private var toasts

    var body: some View {
        Color.clear.onChange(of: model.saveError) { _, error in
            guard let error else { return }
            toasts.show(error, status: .danger, duration: 6)
            model.saveError = nil
        }
    }
}

/// Window-level keys. Hidden buttons, so the chords work wherever focus is inside the window.
private struct Shortcuts: View {
    let model: ForgeModel

    var body: some View {
        // Zero-sized key-equivalent claims, not controls (SwiftUI has no other way without a menu bar).
        // ponytail: three fixed chords; becomes a command list shared with the palette in slice B.
        ZStack {
            Button("Save") { model.saveActive() }.keyboardShortcut("s")  // design-lint: allow raw-control key-equivalent claim
            Button("Close Tab") { if let path = model.tabs.active { model.close(path) } }  // design-lint: allow raw-control key-equivalent claim
                .keyboardShortcut("w")
            Button("Open Folder") { if let url = FolderPicker.choose() { model.request(.open(url)) } }  // design-lint: allow raw-control key-equivalent claim
                .keyboardShortcut("o")
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}
