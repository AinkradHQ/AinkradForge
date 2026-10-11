import AinkradAppKit
import SwiftUI

/// The git-aware file tree. A single click on a file opens a preview tab; a double click keeps it.
struct FileTreeList: View {
    let model: ForgeModel
    let workspace: Workspace
    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(FileTree.visibleRows(workspace.tree, expanded: model.expanded), id: \.node.id) { row in
                    FileRow(
                        node: row.node, depth: row.depth,
                        mark: row.node.isDirectory ? workspace.folderMarks[row.node.path] : workspace.marks[row.node.path],
                        isExpanded: model.expanded.contains(row.node.path),
                        isSelected: model.tabs.active == row.node.path
                    ) {
                        if row.node.isDirectory {
                            model.toggle(folder: row.node.path)
                        } else {
                            model.open(file: row.node.path, pinned: false)
                        }
                    } onDoubleClick: {
                        if !row.node.isDirectory { model.open(file: row.node.path, pinned: true) }
                    }
                }
            }
        }
        .scrollIndicators(.never)
        .overlay {
            if workspace.tree.isEmpty, workspace.isLoading { AinkradSpinner() }
        }
    }
}

/// Files changed against HEAD, flat, with their git mark.
struct ChangesList: View {
    let model: ForgeModel
    let workspace: Workspace
    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(workspace.changes, id: \.path) { change in
                    FileRow(
                        node: FileNode(path: change.path, name: change.path, isDirectory: false, children: []),
                        depth: 0, mark: change.mark, isExpanded: false, isSelected: model.tabs.active == change.path
                    ) {
                        if change.mark != .deleted { model.open(file: change.path, pinned: false) }
                    } onDoubleClick: {
                        if change.mark != .deleted { model.open(file: change.path, pinned: true) }
                    }
                }
            }
        }
        .scrollIndicators(.never)
        .overlay {
            if workspace.changes.isEmpty {
                Text(workspace.branch == nil ? "Not a git repository." : "No changes.")
                    .font(skin.font(AinkradFontToken(sizeKey: "t12")))
                    .foregroundStyle(skin.color(skin.text.faint))
            }
        }
    }
}

struct FileRow: View {
    let node: FileNode
    let depth: Int
    let mark: GitMark?
    let isExpanded: Bool
    let isSelected: Bool
    let onClick: () -> Void
    let onDoubleClick: () -> Void
    @State private var isHovered = false
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradStatusColors) private var statusColors

    var body: some View {
        HStack(spacing: skin.size.s6) {
            Group {
                if node.isDirectory {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(skin.font(AinkradFontToken(sizeKey: "t9", weight: "semibold")))
                        .foregroundStyle(skin.color(skin.text.faint))
                }
            }
            .frame(width: skin.size.s10)
            Image(systemName: FileIcon.symbol(for: node))
                .font(skin.font(AinkradFontToken(sizeKey: "t11")))
                .foregroundStyle(
                    node.isDirectory
                        ? theme.accentSecondary : FileIcon.tint(for: node.name, theme: theme) ?? skin.color(skin.text.faint))
                .frame(width: skin.size.s14)
            Text(node.name)
                .font(skin.font(AinkradFontToken(sizeKey: "t12")))
                .foregroundStyle(nameColor)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: skin.size.s4)
            if let mark {
                Text(mark.rawValue)
                    .font(skin.font(AinkradFontToken(sizeKey: "t10", weight: "semibold", monospacedDigits: true)))
                    .foregroundStyle(color(for: mark))
            }
        }
        .padding(.vertical, skin.size.s3)
        .padding(.leading, skin.size.s6 + CGFloat(depth) * skin.size.s14)
        .padding(.trailing, skin.size.s8)
        .ainkradRowBackground(isSelected: isSelected, isHovered: isHovered)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        // The single click fires at once (no wait for a possible second click); the double click then pins.
        .onTapGesture(count: 2, perform: onDoubleClick)
        .simultaneousGesture(TapGesture().onEnded(onClick))
        .help(node.path)
    }

    private var nameColor: Color {
        if let mark { return color(for: mark) }
        return node.isDirectory || isSelected ? theme.foreground.opacity(skin.opacity.o90) : skin.color(skin.text.muted)
    }

    private func color(for mark: GitMark) -> Color {
        switch mark {
        case .modified: statusColors.warning
        case .added: statusColors.success
        case .untracked: theme.accentSecondary
        case .deleted: statusColors.danger
        }
    }
}

/// SF Symbol and tint per file kind. Deliberately small: the name carries the rest.
enum FileIcon {
    static func symbol(for node: FileNode) -> String {
        if node.isDirectory { return "folder.fill" }
        switch (node.name as NSString).pathExtension.lowercased() {
        case "swift": return "swift"
        case "md", "markdown", "txt": return "doc.text"
        case "json", "yml", "yaml", "toml", "plist", "xml": return "curlybraces"
        case "png", "jpg", "jpeg", "gif", "svg", "pdf", "icns": return "photo"
        case "sh", "zsh", "bash": return "terminal"
        default: return "doc"
        }
    }

    /// `nil` = the plain faint text colour.
    static func tint(for name: String, theme: HostThemeTokens) -> Color? {
        switch (name as NSString).pathExtension.lowercased() {
        case "swift": theme.accentTertiary
        case "md", "markdown": theme.accentSecondary
        case "json", "yml", "yaml", "toml": theme.accentPrimary
        default: nil
        }
    }
}
