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

    /// `.f .rename`: a row-height field on a dark wash with a thin cyan stroke, so the row stays in place.
    var body: some View {
        HStack(spacing: skin.size.s6) {
            Color.clear.frame(width: skin.size.s10)
            FileGlyph(name: initial, isDirectory: isDirectory)
            TextField(isDirectory ? "Folder name" : "File name", text: $name)  // design-lint: allow raw-control row-height rename field (the kit field is taller than a row)
                .textFieldStyle(.plain)
                .font(skin.font(AinkradFontToken(sizeKey: "t12_5")))
                .foregroundStyle(theme.foreground)
                .tint(theme.accentSecondary)
                .padding(.vertical, skin.size.s1)
                .padding(.horizontal, skin.size.s5)
                .background(RoundedRectangle(cornerRadius: skin.size.s4).fill(skin.color(skin.palette.black).opacity(skin.opacity.o35)))
                .overlay(RoundedRectangle(cornerRadius: skin.size.s4).strokeBorder(theme.accentSecondary, lineWidth: skin.size.s1))
                .frame(maxWidth: .infinity)
                .focused($focused)
                .onSubmit { model.commitTreeEdit(name) }
                .onExitCommand { model.treeEdit = nil }
        }
        .padding(.vertical, skin.size.s2)
        .padding(.leading, skin.size.s8 + CGFloat(depth) * skin.size.s14)
        .padding(.trailing, skin.size.s8)
        .onAppear {
            name = initial
            DispatchQueue.main.async { focused = true }  // see Palette's onAppear
        }
        .onChange(of: focused) { _, isFocused in
            if isFocused {
                hadFocus = true
                // Finder's rename: the name without its extension is selected, so typing replaces just the name.
                DispatchQueue.main.async {
                    let editors = NSApp.windows.compactMap { $0.firstResponder as? NSTextView }
                    editors.first { $0.string == name }?.setSelectedRange(ainkradBaseNameRange(name))
                }
                return
            }
            guard hadFocus, model.treeEdit != nil else { return }
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == initial { model.treeEdit = nil } else { model.commitTreeEdit(name) }
        }
    }
}

/// The tree's right-click menus. Groups are separated by space (the kit menu), never by lines.
enum TreeMenu {
    /// `New File… ⌘N · New Folder… ⌥⌘N` | `Rename · Duplicate · Copy Path ⌥⌘C · Copy Relative Path` |
    /// `Reveal in Finder ⌥⌘R · Open in Terminal · Open in Git Mage` | `Move to Trash` — no icons, groups by space.
    @MainActor static func items(for node: FileNode, model: ForgeModel) -> [AinkradMenuItem] {
        let folder = model.folder(for: node.path, isDirectory: node.isDirectory)
        let url = model.workspace?.url(for: node.path)
        var items = [
            AinkradMenuItem(title: "New File…", systemName: nil, shortcut: "⌘N") { model.beginNew(folder: false, in: folder) },
            AinkradMenuItem(title: "New Folder…", systemName: nil, shortcut: "⌥⌘N") { model.beginNew(folder: true, in: folder) },
            AinkradMenuItem(title: "Rename", systemName: nil) { model.beginRename(node.path) }.startingGroup(),
        ]
        if !node.isDirectory {
            items.append(AinkradMenuItem(title: "Duplicate", systemName: nil) { model.duplicate(node.path) })
        }
        items += [
            AinkradMenuItem(title: "Copy Path", systemName: nil, shortcut: "⌥⌘C") { copy(url?.path(percentEncoded: false)) },
            AinkradMenuItem(title: "Copy Relative Path", systemName: nil) { copy(node.path) },
            AinkradMenuItem(title: "Reveal in Finder", systemName: nil, shortcut: "⌥⌘R") {
                if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }.startingGroup(),
            AinkradMenuItem(title: "Open in Terminal", systemName: nil) {
                model.openTerminal(in: model.workspace?.url(for: folder))
            },
            AinkradMenuItem(title: "Open in Git Mage", systemName: nil) { model.openGitMage() },
            AinkradMenuItem(title: "Move to Trash", systemName: nil, isDestructive: true) { model.trash(node.path) }.startingGroup(),
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
