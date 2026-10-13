import AinkradAppKit
import SwiftUI

/// Workspace card, the Files / Changes / Search / Problems tabs, and the active tab's list.
/// Surfaces are told apart by fill, never by a line.
struct Sidebar: View {
    @Bindable var model: ForgeModel
    let workspace: Workspace
    /// 280 pt (`RootView`).
    let width: CGFloat
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The card's content: the sidebar less the card's margins and padding (2×12, 2×10).
            WorkspaceCard(model: model, workspace: workspace, width: width - skin.size.s44)
                .padding(.horizontal, skin.size.s12)
                .padding(.bottom, skin.size.s10)
            SideTabs(model: model, workspace: workspace)
                .padding(.horizontal, skin.size.s12)
                .padding(.bottom, skin.size.s8)
            Group {
                switch model.sideTab {
                case .files:
                    FileTreeList(model: model, workspace: workspace).padding(.horizontal, skin.size.s8)
                case .changes:
                    VStack(alignment: .leading, spacing: 0) {
                        OutsideChangesButton(model: model)
                            .font(skin.font(AinkradFontToken(sizeKey: "t12")))
                            .padding(.horizontal, skin.size.s12)
                            .padding(.bottom, model.agent.count > 0 ? skin.size.s8 : 0)
                        ChangesList(model: model, workspace: workspace).padding(.horizontal, skin.size.s8)
                    }
                case .search: SearchPanel(model: model, workspace: workspace).padding(.horizontal, skin.size.s10)
                case .problems: IssuesList(model: model).padding(.horizontal, skin.size.s10)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.top, skin.size.s12)
        .padding(.bottom, skin.size.s10)
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
        // Fill, not a rule: `.sidebar` — the surface at 55 % (Neon), white at 3.5 % (Glass).
        .background(skin.usesNativeGlass ? skin.color(skin.palette.white).opacity(skin.opacity.o03) : theme.surface.opacity(skin.opacity.o55))
    }
}

/// `Files · Changes 2 · Search · Issues 5` (`.side-tabs`): plain text tabs, the selected one on the `--fill`
/// wash; under Liquid Glass a glass capsule with the selected segment a light pill. Counts once there are any.
private struct SideTabs: View {
    @Bindable var model: ForgeModel
    let workspace: Workspace
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        let glass = skin.usesNativeGlass
        HStack(spacing: glass ? skin.size.s2 : skin.size.s4) {
            ForEach(ForgeModel.SideTab.allCases) { tab in
                SideTabButton(title: title(tab), isOn: model.sideTab == tab, fillsWidth: glass) { model.sideTab = tab }
            }
        }
        .padding(glass ? skin.size.s3 : 0)
        .modifier(GlassCapsule(isOn: glass))
    }

    private func title(_ tab: ForgeModel.SideTab) -> String {
        let count: Int =
            switch tab {
            case .changes: workspace.changes.count
            case .problems: model.languages.allIssues.count
            default: 0
            }
        return count > 0 ? "\(tab.rawValue) \(count)" : tab.rawValue
    }
}

private struct SideTabButton: View {
    let title: String
    let isOn: Bool
    let fillsWidth: Bool
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        // A plain button: keyboard-reachable, styled as the mockup's text tab.
        Button(action: action) {  // design-lint: allow raw-control text tab (kit segmented control is boxed)
            Text(title)
                .font(skin.font(AinkradFontToken(sizeKey: "t11")))
                .foregroundStyle(isOn || isHovered ? theme.foreground : skin.color(skin.text.muted))
                .lineLimit(1)
                .fixedSize()
                .padding(.vertical, skin.size.s4)
                .padding(.horizontal, skin.size.s8)
                .frame(maxWidth: fillsWidth ? .infinity : nil)
                .background(pill)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    @ViewBuilder private var pill: some View {
        if isOn {
            if skin.usesNativeGlass {
                Capsule().fill(skin.color(skin.palette.white).opacity(skin.opacity.o20))
            } else {
                RoundedRectangle(cornerRadius: skin.size.s6, style: .continuous).fill(ForgeStyle.fill(skin, theme))
            }
        }
    }
}

/// Liquid Glass's capsule behind the sidebar tabs (and nothing under Neon).
private struct GlassCapsule: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26, *), isOn {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content
        }
    }
}

/// Name, branch and changed-file count; a click opens the workspace menu (worktrees, recents, open, close).
private struct WorkspaceCard: View {
    let model: ForgeModel
    let workspace: Workspace
    let width: CGFloat
    @State private var isHovered = false
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradStatusColors) private var statusColors

    var body: some View {
        AinkradMenuButton(items: items) {
            VStack(alignment: .leading, spacing: skin.size.s2) {
                HStack {
                    Text(workspace.name)
                        .font(skin.font(AinkradFontToken(sizeKey: "t13", weight: "semibold")))
                        .foregroundStyle(theme.foreground)
                    Spacer(minLength: skin.size.s8)
                    Text("▾").font(skin.font(AinkradFontToken(sizeKey: "t11"))).foregroundStyle(skin.color(skin.text.faint))
                }
                HStack(spacing: skin.size.s6) {
                    if let branch = workspace.branch {
                        Text("⑂ \(branch)")
                    } else {
                        // An empty folder names where it is; otherwise that git is missing (mockup 19 A, B).
                        Text(workspace.files.isEmpty ? (workspace.root.path as NSString).abbreviatingWithTildeInPath : "not a git repository")
                            .foregroundStyle(skin.color(skin.text.faint))
                            .truncationMode(.head)
                    }
                    if !workspace.marks.isEmpty {
                        Text("● \(workspace.marks.count)").foregroundStyle(statusColors.warning)
                    }
                }
                .font(skin.font(AinkradFontToken(sizeKey: "t11", mono: "family", monospacedDigits: true)))
                .foregroundStyle(skin.color(skin.text.muted))
                .lineLimit(1)
            }
            // An explicit width: under Glass the kit's menu button is `.fixedSize()`, so `maxWidth: .infinity`
            // would collapse to the text.
            .frame(width: width, alignment: .leading)
            .padding(.vertical, skin.size.s8)
            .padding(.horizontal, skin.size.s10)
            .modifier(CardSurface(isHovered: isHovered))
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
        }
        // FD20: under Glass Apple's own pull-down is so see-through the tabs behind it read through.
        .kitMenuUnderGlass()
        .help("Switch workspace ⌃⌘O · \(workspace.root.path(percentEncoded: false))")
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

/// The workspace card's surface (`.ws.cut`): under Neon a chamfered card on `--fill-strong` with the cyan
/// `--stroke`; under Liquid Glass interactive glass, 18 pt round. Local only because the kit has no public
/// "card trigger" surface.
private struct CardSurface: ViewModifier {
    let isHovered: Bool
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    func body(content: Content) -> some View {
        if #available(macOS 26, *), skin.usesNativeGlass {
            content.glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: skin.size.s18, style: .continuous))
        } else {
            let shape = skin.shape(cut: skin.cut.c8)
            content
                .background(shape.fill(ForgeStyle.fillStrong(skin, theme)))
                .overlay(shape.strokeBorder(ForgeStyle.stroke(skin, theme), lineWidth: skin.size.s1))
                .brightness(isHovered ? skin.opacity.o03 : 0)
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
