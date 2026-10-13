import AinkradAppKit
import AppKit
import SwiftUI

/// Clone Repository… (mockup 05's third way in): the URL (offered from the clipboard when it holds one), the
/// folder it lands in, git's progress with Cancel, and git's own message when it fails. Kit dialog parts, as
/// the window's other dialogs (`UnsavedDialog`).
struct CloneDialog: View {
    static let width: CGFloat = 440
    let clone: GitClone
    /// The new folder, once cloned.
    let opened: @MainActor (URL) -> Void
    let close: () -> Void
    @FocusState private var urlFocused: Bool
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradStatusColors) private var status

    var body: some View {
        @Bindable var clone = clone
        VStack(alignment: .leading, spacing: skin.size.s12) {
            Text("Clone Repository").font(skin.font(AinkradFontToken(sizeKey: "t15", weight: "semibold")))
            VStack(alignment: .leading, spacing: skin.size.s6) {
                label("Repository URL")
                AinkradTextField(text: $clone.url, placeholder: "https://github.com/owner/repo.git or git@host:owner/repo", focus: $urlFocused)
                    .disabled(clone.isCloning)
                    .onSubmit(start)
            }
            VStack(alignment: .leading, spacing: skin.size.s6) {
                label("Clone into")
                HStack(spacing: skin.size.s8) {
                    Text(((clone.destination ?? clone.parent).path as NSString).abbreviatingWithTildeInPath)
                        .font(skin.font(AinkradFontToken(sizeKey: "t12", mono: "family")))
                        .foregroundStyle(skin.color(skin.text.muted))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    AinkradButton(title: "Choose…", style: .secondary) {
                        if let folder = FolderPicker.choose() { clone.parent = folder }
                    }
                    .fixedSize()
                    .disabled(clone.isCloning)
                }
            }
            state
            HStack(spacing: skin.size.s8) {
                Spacer(minLength: skin.size.s8)
                AinkradButton(title: "Cancel", style: .secondary) {
                    if clone.isCloning { clone.cancel() } else { close() }
                }
                .fixedSize()
                .keyboardShortcut(.cancelAction)
                AinkradButton(title: clone.isCloning ? "Cloning…" : "Clone", style: .primary, action: start)
                    .fixedSize()
                    .disabled(clone.isCloning || clone.destination == nil)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(skin.size.s20)
        .onAppear {
            // Paste detection: a repository URL on the clipboard fills the field.
            if clone.url.isEmpty, let text = NSPasteboard.general.string(forType: .string), GitClone.looksLikeRepository(text) {
                clone.url = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            DispatchQueue.main.async { urlFocused = true }  // a turn later, or the field ignores it
        }
    }

    /// git's progress (step, meter, percentage) while it runs; its message, in the danger colour, when it failed.
    @ViewBuilder private var state: some View {
        switch clone.phase {
        case .editing:
            EmptyView()
        case .cloning(let step, let fraction):
            HStack(spacing: skin.size.s8) {
                if fraction == nil { AinkradSpinner(size: skin.size.s10) }
                Text(step)
                if let fraction {
                    ProgressMeter(fraction: fraction)
                    Text("\(Int(fraction * 100))%").monospacedDigit()
                }
            }
            .font(skin.font(AinkradFontToken(sizeKey: "t11")))
            .foregroundStyle(skin.color(skin.text.muted))
        case .failed(let message):
            Text(message)
                .font(skin.font(AinkradFontToken(sizeKey: "t11")))
                .foregroundStyle(status.danger)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private func label(_ text: String) -> some View {
        Text(skin.labelCased(text))
            .font(skin.font(AinkradFontToken(sizeKey: "t10", weight: "semibold")))
            .tracking(skin.usesNativeGlass ? 0 : skin.size.s10 * 0.08)
            .foregroundStyle(skin.color(skin.text.muted))
    }

    private func start() {
        clone.start(done: opened)
    }
}
