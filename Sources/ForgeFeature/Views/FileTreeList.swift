import AinkradAppKit
import SwiftUI

/// The git-aware file tree. A single click on a file opens a preview tab; a double click keeps it.
/// Right-click for file operations; drag a row onto a folder to move it; drop files from Finder to copy them in.
struct FileTreeList: View {
    let model: ForgeModel
    let workspace: Workspace
    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                let visible = FileTree.visibleRows(workspace.tree, expanded: model.expanded)
                ForEach(Self.rows(visible, edit: model.treeEdit)) { row in
                    switch row {
                    case .node(let node, let depth):
                        if model.treeEdit == .rename(node.path) {
                            NameField(depth: depth, isDirectory: node.isDirectory, initial: node.name, model: model)
                        } else {
                            nodeRow(node, depth: depth)
                        }
                    case .new(let isFolder, let depth):
                        NameField(depth: depth, isDirectory: isFolder, initial: "", model: model)
                    }
                }
            }
            .padding(.bottom, skin.size.s40)
        }
        .scrollIndicators(.never)
        // Empty space below the rows is the workspace root: a drop there lands at the top level.
        .dropDestination(for: URL.self) { urls, _ in drop(urls, into: "") }
        .ainkradContextMenu(TreeMenu.rootItems(model: model))
        .overlay {
            if workspace.tree.isEmpty, workspace.isLoading {
                AinkradSpinner()
            } else if workspace.tree.isEmpty, model.treeEdit == nil {
                // An empty folder: say so, and offer the first file (E1D1 FD32).
                AinkradEmptyState(
                    icon: "folder", title: "This folder is empty",
                    message: "Create a file, or drop files here to copy them in.", actionTitle: "New File"
                ) { model.beginNew(folder: false, in: "") }
                .dropDestination(for: URL.self) { urls, _ in drop(urls, into: "") }
            }
        }
    }

    private func nodeRow(_ node: FileNode, depth: Int) -> some View {
        FileRow(
            node: node, depth: depth,
            mark: node.isDirectory ? workspace.folderMarks[node.path] : workspace.marks[node.path],
            isExpanded: model.expanded.contains(node.path),
            isSelected: model.tabs.active == node.path
        ) {
            if node.isDirectory {
                model.toggle(folder: node.path)
            } else {
                model.open(file: node.path, pinned: false)
            }
        } onDoubleClick: {
            if !node.isDirectory { model.open(file: node.path, pinned: true) }
        }
        .ainkradContextMenu(TreeMenu.items(for: node, model: model))
        .draggable(workspace.url(for: node.path))
        .dropDestination(for: URL.self) { urls, _ in
            drop(urls, into: model.folder(for: node.path, isDirectory: node.isDirectory))
        }
    }

    /// A row dragged within the tree moves; anything from outside the workspace is copied in.
    private func drop(_ urls: [URL], into folder: String) -> Bool {
        var outside: [URL] = []
        for url in urls {
            if let path = workspace.relativePath(of: url) {
                model.move(path, into: folder)
            } else {
                outside.append(url)
            }
        }
        if !outside.isEmpty { model.copyIn(outside, into: folder) }
        return true
    }

    enum Row: Identifiable, Equatable {
        case node(FileNode, depth: Int)
        /// The name field for a new file or folder.
        case new(isFolder: Bool, depth: Int)

        var id: String {
            switch self {
            case .node(let node, _): node.path
            case .new: "\u{0}new"
            }
        }
    }

    /// The visible rows, with a name field slotted in for a new item: first inside its folder (the folder is
    /// expanded by the time this runs), or at the top for the root. Pure, so the placement is tested.
    static func rows(_ visible: [(node: FileNode, depth: Int)], edit: ForgeModel.TreeEdit?) -> [Row] {
        var rows = visible.map { Row.node($0.node, depth: $0.depth) }
        let target: (folder: String, isFolder: Bool)? =
            switch edit {
            case .newFile(let folder): (folder, false)
            case .newFolder(let folder): (folder, true)
            default: nil
            }
        guard let target else { return rows }
        if target.folder.isEmpty {
            rows.insert(.new(isFolder: target.isFolder, depth: 0), at: 0)
        } else if let index = visible.firstIndex(where: { $0.node.path == target.folder }) {
            rows.insert(.new(isFolder: target.isFolder, depth: visible[index].depth + 1), at: index + 1)
        }
        return rows
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
            if workspace.branch == nil, !workspace.isLoading {
                // E6: what needs git, and the way to it; the rest of Forge works without.
                AinkradEmptyState(
                    icon: "arrow.triangle.branch", title: "Not a git repository",
                    message: "Changes, gutter marks and blame need git. The rest works as usual.",
                    actionTitle: "Initialize Repository"
                ) { model.initializeRepository() }
            } else if workspace.changes.isEmpty {
                Text("No changes.")
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
        // A plain button, so Full Keyboard Access can focus it and Space opens it (E1D1 FD34). The single click
        // fires at once (no wait for a possible second click); the double click then pins.
        Button(action: onClick) { label }  // design-lint: allow raw-control keyboard-reachable row (kit has no row button)
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture(count: 2).onEnded(onDoubleClick))
            .help(node.path)
    }

    private var label: some View {
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
                    onSelection ?? (node.isDirectory
                        ? theme.accentSecondary : FileIcon.tint(for: node.name, theme: theme) ?? skin.color(skin.text.faint)))
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
                    .foregroundStyle(onSelection ?? color(for: mark))
            }
        }
        .padding(.vertical, skin.size.s3)
        .padding(.leading, skin.size.s6 + CGFloat(depth) * skin.size.s14)
        .padding(.trailing, skin.size.s8)
        .ainkradRowBackground(isSelected: isSelected, isHovered: isHovered)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    /// Under Glass a selected row is filled with the accent, which drowned the accent-blue of an untracked name
    /// (E1D1 FD31) and dulled every other tint: there the row's text takes the colour readable on the accent, as
    /// the kit's own row text does. Neon's selection is a faint wash, so the git colours stay.
    private var onSelection: Color? {
        isSelected && skin.usesNativeGlass ? skin.color(skin.palette.accentPrimary).contrastingText : nil
    }

    private var nameColor: Color {
        if let onSelection { return onSelection }
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
