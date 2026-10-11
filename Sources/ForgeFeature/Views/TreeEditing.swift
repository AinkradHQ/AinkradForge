import AinkradAppKit
import AppKit
import SwiftUI

/// The inline name field: renaming a row, or naming a new file or folder. Return commits, Esc cancels, and
/// clicking away commits — as Finder and VS Code do (an empty or unchanged name just ends the edit).
struct NameField: View {
    let depth: Int
    let isDirectory: Bool
    let initial: String
    let model: ForgeModel
    @State private var name = ""
    @FocusState private var focused: Bool
    /// Blur only means "done" after the field has had focus — not while it is still being shown.
    @State private var hadFocus = false
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        HStack(spacing: skin.size.s6) {
            Color.clear.frame(width: skin.size.s10)
            Image(systemName: FileIcon.symbol(for: FileNode(path: initial, name: initial, isDirectory: isDirectory, children: [])))
                .font(skin.font(AinkradFontToken(sizeKey: "t11")))
                .foregroundStyle(
                    isDirectory ? theme.accentSecondary : FileIcon.tint(for: initial, theme: theme) ?? skin.color(skin.text.faint))
                .frame(width: skin.size.s14)
            AinkradTextField(text: $name, placeholder: isDirectory ? "Folder name" : "File name")
                .frame(maxWidth: .infinity)
                .focused($focused)
                .onSubmit { model.commitTreeEdit(name) }
                .onExitCommand { model.treeEdit = nil }
        }
        .padding(.vertical, skin.size.s2)
        .padding(.leading, skin.size.s6 + CGFloat(depth) * skin.size.s14)
        .padding(.trailing, skin.size.s8)
        .onAppear {
            name = initial
            focused = true
        }
        .onChange(of: focused) { _, isFocused in
            if isFocused { hadFocus = true; return }
            guard hadFocus, model.treeEdit != nil else { return }
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == initial { model.treeEdit = nil } else { model.commitTreeEdit(name) }
        }
    }
}

/// The tree's right-click menus. Groups are separated by space (the kit menu), never by lines.
enum TreeMenu {
    @MainActor static func items(for node: FileNode, model: ForgeModel) -> [AinkradMenuItem] {
        let folder = model.folder(for: node.path, isDirectory: node.isDirectory)
        let url = model.workspace?.url(for: node.path)
        var items = [
            AinkradMenuItem(title: "New File…", systemName: "doc.badge.plus") { model.beginNew(folder: false, in: folder) },
            AinkradMenuItem(title: "New Folder…", systemName: "folder.badge.plus") { model.beginNew(folder: true, in: folder) },
            AinkradMenuItem(title: "Rename", systemName: "pencil") { model.beginRename(node.path) },
        ]
        if !node.isDirectory {
            items.append(AinkradMenuItem(title: "Duplicate", systemName: "plus.square.on.square") { model.duplicate(node.path) })
            items.append(AinkradMenuItem(title: "Open to the Side", systemName: "rectangle.split.2x1") {
                model.open(file: node.path, pinned: true)
                model.splitEditor(stacked: false)
            })
        }
        items += [
            AinkradMenuItem(title: "Copy Path", systemName: "doc.on.clipboard") { copy(url?.path(percentEncoded: false)) },
            AinkradMenuItem(title: "Copy Relative Path", systemName: "doc.on.clipboard") { copy(node.path) },
            AinkradMenuItem(title: "Reveal in Finder", systemName: "folder") {
                if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            },
            AinkradMenuItem(title: "Move to Trash", systemName: "trash", isDestructive: true) { model.trash(node.path) },
        ]
        return items
    }

    /// Right-click on empty space: new items at the workspace root.
    @MainActor static func rootItems(model: ForgeModel) -> [AinkradMenuItem] {
        [
            AinkradMenuItem(title: "New File…", systemName: "doc.badge.plus") { model.beginNew(folder: false, in: "") },
            AinkradMenuItem(title: "New Folder…", systemName: "folder.badge.plus") { model.beginNew(folder: true, in: "") },
            AinkradMenuItem(title: "Reveal in Finder", systemName: "folder") {
                if let root = model.workspace?.root { NSWorkspace.shared.activateFileViewerSelecting([root]) }
            },
        ]
    }

    private static func copy(_ text: String?) {
        guard let text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
