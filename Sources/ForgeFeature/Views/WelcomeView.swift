import AinkradAppKit
import SwiftUI

/// No workspace open: open a folder, or pick a recent one.
struct WelcomeView: View {
    let model: ForgeModel
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        VStack(spacing: skin.size.s20) {
            Image(systemName: ForgeApp.icon)
                .font(skin.font(AinkradFontToken(sizeKey: "t40")))
                .foregroundStyle(theme.accentSecondary)
            Text(skin.labelCased(ForgeApp.displayName))
                .font(skin.font(AinkradFontToken(sizeKey: "t21", weight: "semibold")))
            AinkradButton(title: "Open Folder…", style: .primary, icon: "folder") {
                if let url = FolderPicker.choose() { model.request(.open(url)) }
            }
            .fixedSize()
            if !recents.isEmpty {
                VStack(alignment: .leading, spacing: skin.size.s2) {
                    Text(skin.labelCased("Recent workspaces"))
                        .font(skin.font(AinkradFontToken(sizeKey: "t10", weight: "semibold")))
                        .foregroundStyle(skin.color(skin.text.muted))
                        .padding(.horizontal, skin.size.s10)
                        .padding(.bottom, skin.size.s4)
                    ForEach(recents, id: \.path) { recent in
                        RecentRow(recent: recent) { model.request(.open(URL(fileURLWithPath: $0))) }
                    }
                }
                .padding(skin.size.s8)
                // Up to 560, narrower with the window (E1D1 FD35).
                .frame(maxWidth: skin.size.s560)
                .background(RoundedRectangle(cornerRadius: skin.size.s12).fill(theme.surface.opacity(skin.opacity.o45)))
            }
        }
        .padding(.horizontal, skin.size.s20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Recents whose folder still exists.
    private var recents: [ForgeDocument.Recent] {
        model.store.document.recents.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

private struct RecentRow: View {
    let recent: ForgeDocument.Recent
    /// Opens a folder: the recent itself or one of its worktrees.
    let open: (String) -> Void
    @State private var isHovered = false
    /// The repo's other worktrees, each its own workspace.
    @State private var worktrees: [(path: String, branch: String)] = []
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: skin.size.s2) {
                Text((recent.path as NSString).lastPathComponent)
                    .font(skin.font(AinkradFontToken(sizeKey: "t13", weight: "medium")))
                    .foregroundStyle(theme.foreground.opacity(skin.opacity.o90))
                Text((recent.path as NSString).abbreviatingWithTildeInPath)
                    .font(skin.font(AinkradFontToken(sizeKey: "t11", monospacedDigits: true)))
                    .foregroundStyle(skin.color(skin.text.faint))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !worktrees.isEmpty {
                    HStack(spacing: skin.size.s6) {
                        ForEach(worktrees.prefix(4), id: \.path) { tree in
                            AinkradChip(label: tree.branch, systemName: "arrow.triangle.branch")
                                .onTapGesture { open(tree.path) }
                                .help(tree.path)
                        }
                        if worktrees.count > 4 {
                            Text("+\(worktrees.count - 4)")
                                .font(skin.font(AinkradFontToken(sizeKey: "t11", monospacedDigits: true)))
                                .foregroundStyle(skin.color(skin.text.faint))
                        }
                    }
                    .padding(.top, skin.size.s4)
                }
            }
            Spacer(minLength: skin.size.s8)
            Text(recent.opened.formatted(.relative(presentation: .named)))
                .font(skin.font(AinkradFontToken(sizeKey: "t11", monospacedDigits: true)))
                .foregroundStyle(skin.color(skin.text.faint))
        }
        .padding(.vertical, skin.size.s8)
        .padding(.horizontal, skin.size.s10)
        .ainkradRowBackground(isSelected: false, isHovered: isHovered)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { open(recent.path) }
        .task {
            let output = try? await Git(directory: URL(fileURLWithPath: recent.path)).run(["worktree", "list", "--porcelain"])
            // Compare resolved paths: git reports /private/var/… where the recent may say /var/….
            let resolved = { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
            worktrees = GitParse.worktrees(output ?? "").filter { resolved($0.path) != resolved(recent.path) }
        }
    }
}
