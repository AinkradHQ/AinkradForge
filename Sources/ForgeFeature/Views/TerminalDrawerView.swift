import AinkradAppKit
import SwiftUI

/// The terminal drawer under the editors, on the window's own surface (no rule above it): its tabs, then the
/// active terminal. Drag its top edge to resize.
struct TerminalDrawerView: View {
    let model: ForgeModel
    @State private var dragStart: Double?
    @State private var isGrabHovered = false
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    private var drawer: TerminalDrawer { model.terminals }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: skin.size.s4) {
                ForEach(drawer.tabs) { tab in
                    DrawerTab(tab: tab, isActive: !drawer.showsTasks && (drawer.active == tab.id || drawer.shownPair?.contains(tab.id) == true)) {
                        drawer.select(tab.id)
                    } onClose: {
                        drawer.requestClose(tab.id)
                    }
                }
                // A bare `＋`, as the tabs are bare (`.dt`).
                Button { drawer.add() } label: {  // design-lint: allow raw-control the mockup's bare ＋ tab
                    Text("＋")
                        .font(skin.font(AinkradFontToken(size: 11.5)))
                        .foregroundStyle(skin.color(skin.text.muted))
                        .padding(.vertical, skin.size.s4)
                        .padding(.horizontal, skin.size.s10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(model.titled("New Terminal", .newTerminal))
                Spacer(minLength: skin.size.s8)
                TasksPill(isActive: drawer.showsTasks, help: model.titled("Tasks — run one", .runTask)) { drawer.showsTasks = true }
                AinkradIconButton(
                    systemName: drawer.isMaximised ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                    tooltip: model.titled(drawer.isMaximised ? "Restore" : "Maximise", .maximiseTerminal)
                ) { drawer.isMaximised.toggle() }
                .textGlyph(drawer.isMaximised ? "⤡" : "⤢", size: skin.size.s14)
                .outlineBox()
                AinkradIconButton(systemName: "xmark", tooltip: model.titled("Hide", .toggleTerminal)) { drawer.isOpen = false }
                    .textGlyph("✕", size: skin.size.s14)
                    .outlineBox()
            }
            .padding(.horizontal, skin.size.s10)
            .padding(.top, skin.size.s8)
            .padding(.bottom, skin.size.s4)
            if drawer.showsTasks {
                TaskListView(model: model)
                    .padding(.horizontal, skin.size.s10)
                    .padding(.bottom, skin.size.s8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let pair = drawer.shownPair {
                // Split Terminal: side by side on the drawer's surface, no rule between them; only the active one
                // takes the keyboard when asked.
                HStack(spacing: skin.size.s10) {
                    ForEach(pair, id: \.self) { id in
                        if let view = drawer.view(id) {
                            TerminalHost(view: view, focusRequest: drawer.active == id ? drawer.focusRequest : -1).id(id)
                        }
                    }
                }
                .padding(.horizontal, skin.size.s10)
                .padding(.bottom, skin.size.s8)
            } else if let id = drawer.active, let view = drawer.view(id) {
                TerminalHost(view: view, focusRequest: drawer.focusRequest)
                    .id(id)
                    .padding(.horizontal, skin.size.s10)
                    .padding(.bottom, skin.size.s8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: drawer.isMaximised ? .infinity : nil)
        .frame(height: drawer.isMaximised ? nil : drawer.height)
        // `.drawer`: Neon on the editor pane's near-window fill with square corners; Glass on `--fill`, rounded.
        .background(RoundedRectangle(cornerRadius: skin.usesNativeGlass ? skin.size.s10 : 0).fill(ForgeStyle.pane(skin, theme)))
        .overlay(alignment: .top) { grab }
    }

    /// The resize handle (`.drawer .grab`): a short faint bar, brighter on hover; dragging moves the drawer's top edge.
    private var grab: some View {
        Capsule()
            .fill(
                isGrabHovered || dragStart != nil
                    ? theme.foreground.opacity(skin.opacity.o45) : skin.color(skin.text.faint).opacity(skin.opacity.o50))
            .frame(width: skin.size.s36, height: skin.size.s4)
            .frame(maxWidth: .infinity, minHeight: skin.size.s10)
            .contentShape(Rectangle())
            .offset(y: -skin.size.s8)
            .onHover { isGrabHovered = $0 }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = dragStart ?? drawer.height
                        dragStart = start
                        drawer.isMaximised = false
                        drawer.height = min(900, max(120, start - value.translation.height))
                    }
                    .onEnded { _ in dragStart = nil })
            .animation(skin.animation(skin.motion.hover), value: isGrabHovered)
    }
}

/// The Tasks tab, at the drawer's trailing end.
private struct TasksPill: View {
    let isActive: Bool
    let help: String
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        // A plain button, so Full Keyboard Access reaches it (E1D2 FD40).
        Button(action: action) { label }  // design-lint: allow raw-control keyboard-reachable tab (kit has no tab button)
            .buttonStyle(.plain)
            .help(help)
    }

    private var label: some View {
        Text("▶ Tasks")
            .font(skin.font(AinkradFontToken(size: 11.5)))
            .foregroundStyle(isActive ? theme.foreground : skin.color(skin.text.muted))
            .padding(.vertical, skin.size.s4)
            .padding(.horizontal, skin.size.s10)
            .background(DrawerTabFill(isActive: isActive, isHovered: isHovered))
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
}

/// One terminal's tab: its state (a pulsing dot while a task runs, ✓ / ✗ once it ends) and title.
private struct DrawerTab: View {
    let tab: TerminalDrawer.Tab
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var isHovered = false
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradStatusColors) private var status

    var body: some View {
        HStack(spacing: skin.size.s6) {
            // A plain button, so Full Keyboard Access reaches the tab (E1D2 FD40); the close button stays its own.
            Button(action: onSelect) {  // design-lint: allow raw-control keyboard-reachable tab (kit has no tab button)
                HStack(spacing: skin.size.s6) {
                    badge
                    Text(tab.title)
                        .font(skin.font(AinkradFontToken(size: 11.5)))
                        .foregroundStyle(isActive ? theme.foreground : skin.color(skin.text.muted))
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            // `.dt .x`: a bare faint ✕, on a running or shell tab; a finished task's tab has none until hovered.
            Button(action: onClose) {  // design-lint: allow raw-control the tab's bare ✕ glyph
                Text("✕").font(skin.font(AinkradFontToken(sizeKey: "t9"))).foregroundStyle(skin.color(skin.text.faint))
            }
            .buttonStyle(.plain)
            .help("Close Terminal")
            .opacity(isHovered || !tab.ended || tab.command == nil ? 1 : 0)
        }
        .padding(.vertical, skin.size.s4)
        .padding(.horizontal, skin.size.s10)
        .background(DrawerTabFill(isActive: isActive, isHovered: isHovered))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onSelect)
        .help(tab.command ?? tab.title)
    }

    /// `⌨︎` for a shell, a glowing cyan dot while a task runs, `✓` / `✗` once it ends.
    @ViewBuilder private var badge: some View {
        let font = skin.font(AinkradFontToken(size: 11.5))
        if tab.command == nil {
            Text("⌨︎").font(font).foregroundStyle(isActive ? theme.foreground : skin.color(skin.text.muted))
        } else if !tab.ended {
            Circle().fill(theme.accentSecondary).frame(width: skin.size.s7, height: skin.size.s7)
                .shadow(color: theme.accentSecondary, radius: skin.size.s3)
        } else if tab.exitCode == 0 {
            Text("✓").font(font).foregroundStyle(status.success)
        } else {
            Text("✗").font(font).foregroundStyle(status.danger)
        }
    }
}

/// `.dtabs .dt`: Neon's 6 pt rounded wash (white 7 % when on); Glass's capsule (white 20 % when on).
private struct DrawerTabFill: View {
    let isActive: Bool
    let isHovered: Bool
    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        let white = skin.color(skin.palette.white)
        let fill = isActive ? white.opacity(skin.usesNativeGlass ? skin.opacity.o20 : skin.opacity.o07) : isHovered ? white.opacity(skin.opacity.o05) : .clear
        if skin.usesNativeGlass {
            Capsule().fill(fill)
        } else {
            RoundedRectangle(cornerRadius: skin.size.s6, style: .continuous).fill(fill)
        }
    }
}

/// Puts a terminal the drawer owns on screen. The view outlives this host: leaving the screen only takes it
/// out of its container, so the process keeps running.
private struct TerminalHost: NSViewRepresentable {
    let view: ForgeTerminalView
    let focusRequest: Int

    final class Coordinator {
        var focusRequest = -1
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TerminalContainer { TerminalContainer() }

    func updateNSView(_ container: TerminalContainer, context: Context) {
        container.terminal = view
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            container.focusPending = true
            DispatchQueue.main.async { container.focusIfReady() }
        }
    }

    static func dismantleNSView(_ container: TerminalContainer, coordinator: Coordinator) {
        container.terminal = nil
    }
}

/// Holds the terminal and sizes it to itself — but only at a usable size. A terminal shrunk to a sliver
/// (as a fresh, still zero-sized container would make it) drops to two columns, and the fork, which does
/// not reflow, cuts every line to them for good.
final class TerminalContainer: NSView {
    var terminal: ForgeTerminalView? {
        didSet {
            if oldValue !== terminal, oldValue?.superview === self { oldValue?.removeFromSuperview() }
            fit()
        }
    }

    /// A focus request that came before the terminal was in the window (a new one attaches a turn later, once
    /// it has a usable size) — honoured on attach, or the drawer opens without the keyboard (E0 FD10).
    var focusPending = false

    func focusIfReady() {
        guard focusPending, let terminal, terminal.superview === self, let window else { return }
        focusPending = false
        window.makeFirstResponder(terminal)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fit()
    }

    private func fit() {
        guard let terminal, bounds.width > 100, bounds.height > 40 else { return }
        guard terminal.superview === self else {
            // Not inside a layout pass: adding the terminal brings its constraints, which would re-invalidate
            // the pass that is running and loop.
            DispatchQueue.main.async { [weak self] in self?.attach() }
            return
        }
        if terminal.frame != bounds { terminal.frame = bounds }
    }

    private func attach() {
        guard let terminal, terminal.superview !== self, bounds.width > 100, bounds.height > 40 else { return }
        terminal.removeFromSuperview()
        // In the window first, then sized: a terminal sized (and so started) outside a window draws nothing.
        addSubview(terminal)
        terminal.frame = bounds
        // SwiftTerm repaints only what changed; back on screen, it paints all of itself once.
        terminal.needsDisplay = true
        focusIfReady()
    }
}
