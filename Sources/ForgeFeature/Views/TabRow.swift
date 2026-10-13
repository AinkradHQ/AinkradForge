import AinkradAppKit
import SwiftUI

/// `.tabs`: one window-wide row of every pane's tabs (each pane keeps only its breadcrumb), then split,
/// terminal and more. The active pane's visible tab sits on the `--fill` wash, so it reads as part of the code.
struct TabRow: View {
    let model: ForgeModel
    /// After a tab is picked (the reviews give way to the editor).
    var onPick: () -> Void = {}
    @Environment(\.ainkradSkin) private var skin

    /// Every pane's tabs in order: (pane, path). A file open in both panes is one tab — the active pane's.
    private var entries: [TabEntry] {
        let all = model.panes.indices.flatMap { pane in model.panes[pane].paths.map { TabEntry(pane: pane, path: $0) } }
        var seen = Set<String>()
        return all.compactMap { entry in
            guard seen.insert(entry.path).inserted else { return nil }
            let inActive = model.panes[model.activePane].paths.contains(entry.path)
            return inActive ? TabEntry(pane: model.activePane, path: entry.path) : entry
        }
    }

    private var activeEntry: TabEntry? {
        model.panes[model.activePane].active.map { TabEntry(pane: model.activePane, path: $0) }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: skin.size.s2) {
            // The active tab is kept in view: opening a tenth file must not leave it past the edge (E1D1 FD29).
            ScrollViewReader { proxy in
                strip
                    .onAppear { if let activeEntry { proxy.scrollTo(activeEntry) } }
                    .onChange(of: activeEntry) { _, active in
                        guard let active else { return }
                        withAnimation(skin.animation(skin.motion.hover)) { proxy.scrollTo(active) }
                    }
            }
            TabRowActions(model: model).padding(.bottom, skin.size.s4)
        }
        .padding(.top, skin.size.s12)
        .padding(.horizontal, skin.size.s14)
        .frame(minHeight: skin.size.s44, alignment: .bottom)
    }

    private var strip: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .bottom, spacing: skin.size.s2) {
                ForEach(entries) { entry in
                    let tabs = model.panes[entry.pane]
                    EditorTab(
                        name: (entry.path as NSString).lastPathComponent,
                        isActive: entry == activeEntry, isPreview: tabs.preview == entry.path,
                        isDirty: model.documents[entry.path]?.isDirty == true
                    ) {
                        model.focus(pane: entry.pane)
                        model.activate(entry.path)
                        onPick()
                    } onDoubleClick: {
                        model.focus(pane: entry.pane)
                        model.pin(entry.path)
                        onPick()
                    } onClose: {
                        model.focus(pane: entry.pane)
                        model.close(entry.path)
                    }
                    .help(entry.path)
                    .id(entry)
                }
            }
        }
        .scrollIndicators(.never)
        // No scroll bar: an edge with tabs past it fades out instead, so more tabs read as there (E1D1 FD29).
        .modifier(OverflowFade())
    }
}

struct TabEntry: Hashable, Identifiable {
    let pane: Int
    let path: String
    var id: Self { self }
}

/// Split (⌘\), the terminal drawer (⌃`) and more (⋯) — the mockup's three icon buttons, on existing commands.
private struct TabRowActions: View {
    let model: ForgeModel
    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        HStack(spacing: skin.size.s6) {
            if model.availableCommands.contains(.splitRight) {
                AinkradIconButton(systemName: "rectangle.split.2x1", tooltip: model.titled("Split right", .splitRight)) { model.run(.splitRight) }
            }
            AinkradIconButton(systemName: "keyboard", tooltip: model.titled("Terminal", .toggleTerminal)) { model.run(.toggleTerminal) }
            AinkradMenuButton(items: moreItems) { IconMenuLabel(systemName: "ellipsis") }
                .help("More")
        }
        .fixedSize()
    }

    private var moreItems: [AinkradMenuItem] {
        let commands: [ForgeCommand] = [
            .splitDown, .closePane, .closeTab, .revealInTree, .copyPath, .revealInFinder, .formatDocument, .toggleBlame,
            .maximiseTerminal,
        ]
        return commands.filter(model.availableCommands.contains).map { command in
            AinkradMenuItem(title: command.title, systemName: nil, shortcut: model.shortcut(for: command)?.display) { model.run(command) }
        }
    }
}

/// `.icon-btn.cut` as a menu button's label (a kit icon button inside the menu button would eat the click):
/// 30 pt, chamfered on `--fill-strong` with the `--stroke` hairline; a glass circle under Liquid Glass.
private struct IconMenuLabel: View {
    let systemName: String
    @State private var isHovered = false
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        let glyph = Image(systemName: systemName)
            .font(skin.font(AinkradFontToken(sizeKey: "t13", weight: "semibold")))
            .foregroundStyle(theme.foreground)
            .frame(width: skin.size.s30, height: skin.size.s30)
        Group {
            if #available(macOS 26, *), skin.usesNativeGlass {
                glyph.glassEffect(.regular.interactive(), in: .circle)
            } else {
                let shape = skin.shape(cut: skin.cut.c6)
                glyph
                    .background(shape.fill(ForgeStyle.fillStrong(skin, theme)))
                    .overlay(shape.strokeBorder(isHovered ? theme.accentSecondary : ForgeStyle.stroke(skin, theme), lineWidth: skin.size.s1))
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

/// Fades a horizontal scroll view's edge while content is scrolled out past it. macOS 15+ (scroll geometry);
/// earlier, no fade.
private struct OverflowFade: ViewModifier {
    /// Leading, trailing.
    @State private var hidden = [false, false]
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content
                .onScrollGeometryChange(for: [Bool].self) { geometry in
                    let offset = geometry.contentOffset.x
                    return [offset > 1, offset + geometry.containerSize.width < geometry.contentSize.width - 1]
                } action: { _, edges in
                    hidden = edges
                }
                .mask {
                    HStack(spacing: 0) {
                        LinearGradient(colors: [.clear, theme.foreground], startPoint: .leading, endPoint: .trailing)
                            .frame(width: hidden[0] ? skin.size.s28 : 0)
                        Rectangle()
                        LinearGradient(colors: [theme.foreground, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: hidden[1] ? skin.size.s28 : 0)
                    }
                }
        } else {
            content
        }
    }
}

/// `.tab`: the type glyph, the name (12 pt; italic while a preview), then the dirty dot or a faint `✕` —
/// shown on the active tab and on hover. The active tab sits on `--fill`, rounded on top.
struct EditorTab: View {
    let name: String
    /// Shown instead of `name` (whose extension still picks the glyph): "SidebarRow.swift ↔ Replace preview".
    var title: String?
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
        HStack(spacing: skin.size.s7) {
            FileGlyph(name: name)
            Text(title ?? name)
                .font(skin.font(AinkradFontToken(sizeKey: "t12")))
                .italic(isPreview)
                .foregroundStyle(isActive || isHovered ? theme.foreground : skin.color(skin.text.muted))
                .lineLimit(1)
            // The dirty dot gives way to ✕ while hovered, as in Xcode.
            ZStack {
                if isDirty && !isHovered {
                    Circle().fill(theme.foreground.opacity(skin.opacity.o70)).frame(width: skin.size.s7, height: skin.size.s7)
                } else {
                    Button(action: onClose) {  // design-lint: allow raw-control the tab's bare ✕ glyph
                        Text("✕").font(skin.font(AinkradFontToken(sizeKey: "t10"))).foregroundStyle(skin.color(skin.text.faint))
                    }
                    .buttonStyle(.plain)
                    .opacity(isHovered || isActive ? 1 : 0)
                    .help("Close (⌘W)")
                }
            }
            .frame(width: skin.size.s10, height: skin.size.s10)
        }
        .padding(.vertical, skin.size.s7)
        .padding(.horizontal, skin.size.s12)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: skin.size.s8, topTrailingRadius: skin.size.s8)
                .fill(isActive ? ForgeStyle.fill(skin, theme) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2, perform: onDoubleClick)
        .simultaneousGesture(TapGesture().onEnded(onSelect))
    }
}
