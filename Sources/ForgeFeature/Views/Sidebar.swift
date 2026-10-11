import AinkradAppKit
import SwiftUI

/// Workspace card, the Files / Changes / Search / Problems tabs, and the active tab's list.
/// Surfaces are told apart by fill, never by a line.
struct Sidebar: View {
    @Bindable var model: ForgeModel
    let workspace: Workspace
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: skin.size.s8) {
            WorkspaceCard(model: model, workspace: workspace)
            // The kit's segmented control: Apple's glass segmented picker under Liquid Glass.
            // Labels stay short so all four fit; the change count is on the workspace card.
            AinkradSegmentedPicker(items: ForgeModel.SideTab.allCases, selection: $model.sideTab) { $0.rawValue }
                // Apple's segmented control takes its natural width (the kit fixes its size); small fits 300 pt.
                .controlSize(.small)
            Group {
                switch model.sideTab {
                case .files: FileTreeList(model: model, workspace: workspace)
                case .changes: ChangesList(model: model, workspace: workspace)
                case .search: SearchPanel(model: model, workspace: workspace)
                case .problems:
                    SidebarPlaceholder(icon: "exclamationmark.triangle", text: "Issues arrive with language servers (E5).")
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.top, skin.size.s12)
        .padding(.horizontal, skin.size.s10)
        .padding(.bottom, skin.size.s10)
        .frame(width: skin.size.s300)
        .frame(maxHeight: .infinity, alignment: .top)
        // Fill, not a rule.
        .background(theme.surface.opacity(skin.opacity.o35))
    }
}

/// Name, branch and changed-file count; a click opens the workspace menu (worktrees, recents, open, close).
private struct WorkspaceCard: View {
    let model: ForgeModel
    let workspace: Workspace
    @State private var isHovered = false
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradStatusColors) private var statusColors

    var body: some View {
        AinkradMenuButton(items: items) {
            VStack(alignment: .leading, spacing: skin.size.s3) {
                HStack {
                    Text(workspace.name)
                        .font(skin.font(AinkradFontToken(sizeKey: "t13", weight: "semibold")))
                        .foregroundStyle(theme.foreground.opacity(skin.opacity.o95))
                    Spacer(minLength: skin.size.s4)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(skin.font(AinkradFontToken(sizeKey: "t9", weight: "semibold")))
                        .foregroundStyle(skin.color(skin.text.faint))
                }
                HStack(spacing: skin.size.s6) {
                    if let branch = workspace.branch {
                        Label(branch, systemImage: "arrow.triangle.branch").labelStyle(.titleAndIcon)
                    } else {
                        Text("Not a git repository")
                    }
                    if !workspace.marks.isEmpty {
                        Text("● \(workspace.marks.count)").foregroundStyle(statusColors.warning)
                    }
                }
                .font(skin.font(AinkradFontToken(sizeKey: "t11", monospacedDigits: true)))
                .foregroundStyle(skin.color(skin.text.muted))
                .lineLimit(1)
            }
            // An explicit width: under Glass the kit's menu button is `.fixedSize()`, so `maxWidth: .infinity`
            // would collapse to the text. 300 (sidebar) − 2×10 (sidebar padding) − 2×10 (card padding).
            .frame(width: skin.size.s260, alignment: .leading)
            .padding(.vertical, skin.size.s8)
            .padding(.horizontal, skin.size.s10)
            .modifier(CardSurface(isHovered: isHovered))
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
        }
        .help(workspace.root.path(percentEncoded: false))
    }

    private var items: [AinkradMenuItem] {
        let here = workspace.root.path(percentEncoded: false)
        let resolved = { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        let worktrees = workspace.worktrees.filter { resolved($0.path) != resolved(here) }.map { tree in
            AinkradMenuItem(title: "⑂ \(tree.branch)", systemName: nil) {
                model.request(.open(URL(fileURLWithPath: tree.path)))
            }
        }
        let recents = model.store.document.recents.filter { $0.path != here }.prefix(6).map { recent in
            AinkradMenuItem(title: (recent.path as NSString).lastPathComponent, systemName: "clock") {
                model.request(.open(URL(fileURLWithPath: recent.path)))
            }
        }
        return worktrees + recents + [
            AinkradMenuItem(title: "Open Folder…", systemName: "folder", shortcut: "\u{2318}O") {
                if let url = FolderPicker.choose() { model.request(.open(url)) }
            },
            AinkradMenuItem(title: "Close Workspace", systemName: "xmark") { model.request(.close) },
        ]
    }
}

/// The workspace card's surface: interactive Liquid Glass under the Glass theme (as Apple's pop-up buttons),
/// the kit's row fill elsewhere. Local only because the kit has no public "card trigger" surface.
private struct CardSurface: ViewModifier {
    let isHovered: Bool
    @Environment(\.ainkradSkin) private var skin

    func body(content: Content) -> some View {
        if #available(macOS 26, *), skin.usesNativeGlass {
            content.glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: skin.size.s16, style: .continuous))
        } else {
            content.ainkradRowBackground(isSelected: false, isHovered: isHovered)
        }
    }
}

private struct SidebarPlaceholder: View {
    let icon: String
    let text: String
    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        Label(text, systemImage: icon)
            .font(skin.font(AinkradFontToken(sizeKey: "t12")))
            .foregroundStyle(skin.color(skin.text.faint))
            .padding(skin.size.s10)
    }
}

/// Asks for a folder to open as a workspace.
enum FolderPicker {
    @MainActor static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Open"
        return panel.runModal() == .OK ? panel.url : nil
    }
}
