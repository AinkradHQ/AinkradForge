import AinkradAppKit
import SwiftUI

/// Tabs, the active file's breadcrumb and editor, and the status bar — one surface, no rules.
struct EditorArea: View {
    let model: ForgeModel
    let workspace: Workspace
    let palette: HostTerminalPalette?
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            TabStrip(model: model)
            Group {
                if let path = model.tabs.active, let document = model.documents[path] {
                    VStack(alignment: .leading, spacing: 0) {
                        AinkradBreadcrumb(items: path.split(separator: "/").map(String.init))
                            .padding(.horizontal, skin.size.s14)
                            .padding(.top, skin.size.s8)
                            .padding(.bottom, skin.size.s4)
                        DocumentView(
                            document: document, palette: palette, goToLine: model.pendingLine,
                            onGoToLineHandled: { model.pendingLine = nil }
                        ) { model.didEdit(path) }
                        .id(path)
                    }
                } else {
                    AinkradEmptyState(
                        icon: "doc.text", title: "No file open",
                        message: "Pick a file in the sidebar. A single click previews it; a double click keeps it open.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: model.tabs.paths.isEmpty ? skin.size.s10 : 0, bottomLeadingRadius: skin.size.s10,
                    bottomTrailingRadius: skin.size.s10, topTrailingRadius: skin.size.s10
                )
                .fill(theme.surface.opacity(skin.opacity.o45))
            )
            .padding(.horizontal, skin.size.s14)
            StatusRow(model: model, workspace: workspace)
        }
    }
}

private struct DocumentView: View {
    let document: EditorDocument
    let palette: HostTerminalPalette?
    let goToLine: Int?
    let onGoToLineHandled: () -> Void
    let onEdit: () -> Void

    var body: some View {
        switch document.state {
        case .loading: AinkradLoadingState(label: "Opening \(document.url.lastPathComponent)…")
        case .unreadable(let why):
            AinkradEmptyState(icon: "doc.questionmark", title: "Can't show this file", message: why)
        case .ready:
            CodeEditor(
                document: document, palette: palette, goToLine: goToLine, onGoToLineHandled: onGoToLineHandled,
                onEdit: onEdit)
        }
    }
}

/// Open files. The active tab shares the editor pane's fill, so it reads as part of it.
private struct TabStrip: View {
    let model: ForgeModel
    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: skin.size.s2) {
                ForEach(model.tabs.paths, id: \.self) { path in
                    EditorTab(
                        name: (path as NSString).lastPathComponent,
                        isActive: model.tabs.active == path, isPreview: model.tabs.preview == path,
                        isDirty: model.documents[path]?.isDirty == true
                    ) {
                        model.activate(path)
                    } onDoubleClick: {
                        model.pin(path)
                    } onClose: {
                        model.close(path)
                    }
                    .help(path)
                }
            }
            .padding(.horizontal, skin.size.s14)
        }
        .scrollIndicators(.never)
        .padding(.top, skin.size.s12)
        .frame(height: skin.size.s44, alignment: .bottom)
    }
}

private struct EditorTab: View {
    let name: String
    let isActive: Bool
    let isPreview: Bool
    let isDirty: Bool
    let onSelect: () -> Void
    let onDoubleClick: () -> Void
    let onClose: () -> Void
    @State private var isHovered = false
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        HStack(spacing: skin.size.s6) {
            Image(systemName: FileIcon.symbol(for: FileNode(path: name, name: name, isDirectory: false, children: [])))
                .font(skin.font(AinkradFontToken(sizeKey: "t10")))
                .foregroundStyle(FileIcon.tint(for: name, theme: theme) ?? skin.color(skin.text.faint))
            Text(name)
                .font(skin.font(AinkradFontToken(sizeKey: "t12", weight: isActive ? "medium" : "regular")))
                .italic(isPreview)
                .foregroundStyle(isActive ? theme.foreground : skin.color(skin.text.muted))
                .lineLimit(1)
            // The dirty dot gives way to ✕ while hovered, as in Xcode.
            ZStack {
                if isDirty && !isHovered {
                    Circle().fill(theme.foreground.opacity(skin.opacity.o70)).frame(width: skin.size.s7, height: skin.size.s7)
                } else if isHovered || isActive {
                    AinkradIconButton(systemName: "xmark", size: skin.size.s16, tooltip: "Close (⌘W)", action: onClose)
                }
            }
            .frame(width: skin.size.s16, height: skin.size.s16)
        }
        .padding(.vertical, skin.size.s7)
        .padding(.leading, skin.size.s12)
        .padding(.trailing, skin.size.s6)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: skin.size.s8, topTrailingRadius: skin.size.s8)
                .fill(isActive ? theme.surface.opacity(skin.opacity.o45) : isHovered ? theme.foreground.opacity(skin.opacity.o05) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2, perform: onDoubleClick)
        .simultaneousGesture(TapGesture().onEnded(onSelect))
    }
}

/// Branch, cursor and language. Encoding, line endings and language-server state join with E3 and E5.
private struct StatusRow: View {
    let model: ForgeModel
    let workspace: Workspace
    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        HStack(spacing: skin.size.s14) {
            if let branch = workspace.branch {
                Label(branch, systemImage: "arrow.triangle.branch")
            }
            if workspace.isLoading { AinkradSpinner() }
            Spacer(minLength: skin.size.s8)
            if let document = model.activeDocument, document.state == .ready {
                Text("Ln \(document.cursor.line), Col \(document.cursor.column)")
                Text(document.language.name)
            }
        }
        .font(skin.font(AinkradFontToken(sizeKey: "t11", monospacedDigits: true)))
        .foregroundStyle(skin.color(skin.text.muted))
        .lineLimit(1)
        .padding(.horizontal, skin.size.s18)
        .padding(.vertical, skin.size.s8)
    }
}
