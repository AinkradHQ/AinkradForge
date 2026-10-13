import AinkradAppKit
import SwiftUI

/// One row of the palette, whichever mode it is in.
struct PaletteItem: Hashable, Identifiable {
    enum Payload: Hashable {
        case file(String)
        case command(ForgeCommand)
        case line(Int)
        case task(WorkspaceTask)
    }

    let id: String
    let title: String
    let systemName: String
    /// The folder, for files.
    let detail: String?
    /// The keycap, for commands — shown trailing.
    var value: String?
    let payload: Payload
    /// The group caption it falls under (`Recently opened`, `Files`, `Recently used`); nil starts none.
    var section: String?
    /// The title's letters the query matched, drawn bold.
    var matched: [Int] = []
}

/// ⌘P / ⌘⇧P / ⌃G — one panel; the first character picks the mode, as in VS Code:
/// nothing = files, `>` = commands, `:` = go to line.
struct Palette: View {
    let model: ForgeModel
    let start: String
    /// The mode's character ("", ">" or ":"), kept out of the field: macOS selects a focused field's text,
    /// so a prefilled ">" would be replaced by the first letter typed.
    @State private var prefix = ""
    @State private var query = ""
    @State private var highlight: Int?
    @FocusState private var focused: Bool
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        ZStack(alignment: .top) {
            // Click-off scrim: dims the work without hiding it.
            skin.color(.palette("black", skin.opacity.o25))
                .contentShape(Rectangle())
                .onTapGesture { model.palette = nil }
                .accessibilityHidden(true)
            panel.padding(.top, skin.size.s64)
        }
        // Through the responder chain (the field has focus), not a key-equivalent claim on Esc.
        .onExitCommand { model.palette = nil }
    }

    private var items: [PaletteItem] {
        Self.items(for: prefix + query, model: model)
    }

    /// `.palette`: the bare query line (`⌕ sbrow` with the mode's keycap), the results, the footer.
    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: skin.size.s10) {
                Text(prefix == ">" ? "›" : prefix == ":" ? ":" : prefix == "!" ? "▶" : "⌕")
                    .foregroundStyle(skin.color(skin.text.faint))
                // A bare field (the mockup's `.q`), not the kit's boxed search field.
                TextField(placeholder, text: $query)  // design-lint: allow raw-control the palette's bare query line
                    .textFieldStyle(.plain)
                    .foregroundStyle(theme.foreground)
                    .tint(theme.accentSecondary)
                    .focused($focused)
                    .onSubmit(activateHighlighted)
                    // ⌫ on an empty field leaves command / line mode for files, as in VS Code.
                    .onKeyPress(.delete) {
                        guard query.isEmpty, !prefix.isEmpty else { return .ignored }
                        prefix = ""
                        return .handled
                    }
                if let keys = modeKeys { AinkradKbd(keys).outlined() }
            }
            .font(skin.font(AinkradFontToken(sizeKey: "t14")))
            .padding(.vertical, skin.size.s12)
            .padding(.horizontal, skin.size.s14)
            // Sized to its rows up to a cap, scrolling past it (the kit menu is a plain stack), with the
            // keyboard-highlighted row kept in view.
            ViewThatFits(in: .vertical) {
                menu
                ScrollViewReader { proxy in
                    ScrollView { menu }
                        .scrollIndicators(.never)
                        .onChange(of: highlight) { _, row in
                            if let row, items.indices.contains(row) { proxy.scrollTo(items[row]) }
                        }
                }
            }
            .frame(maxHeight: skin.size.s380)
            .padding(.horizontal, skin.size.s6)
            .padding(.bottom, skin.size.s8)
            HStack(spacing: skin.size.s14) {
                ForEach(hints.leading, id: \.self) { Text($0) }
                Spacer(minLength: skin.size.s14)
                Text(hints.trailing)
            }
            .font(skin.font(AinkradFontToken(sizeKey: "t11")))
            .foregroundStyle(skin.color(skin.text.faint))
            .lineLimit(1)
            .padding(.top, skin.size.s8)
            .padding(.horizontal, skin.size.s14)
            .padding(.bottom, skin.size.s10)
        }
        .frame(width: skin.size.s560)
        .fixedSize(horizontal: false, vertical: true)
        .ainkradPanel()
        .onAppear {
            (prefix, query) = Self.split(start)
            // Next turn: on appear the field is not in the window yet, and the request fell to the first key view
            // (the host's title-bar bell under Full Keyboard Access) — E0 FD2.
            DispatchQueue.main.async { focused = true }
            highlight = items.isEmpty ? nil : 0
        }
        .onChange(of: query) { _, typed in
            // Typing ">" or ":" first switches mode.
            if prefix.isEmpty, let first = typed.first, first == ">" || first == ":" || first == "!" { (prefix, query) = Self.split(typed) }
            // Re-ranking moves rows: a highlight left at row 7 would point at a different file.
            highlight = items.isEmpty ? nil : 0
        }
        .onChange(of: prefix) { _, _ in highlight = items.isEmpty ? nil : 0 }
    }

    /// The chord that opens this mode, as the query line's keycap.
    private var modeKeys: String? {
        switch prefix {
        case ">": ForgeCommand.commandPalette.shortcut?.display
        case ":": ForgeCommand.goToLine.shortcut?.display
        case "!": nil
        default: ForgeCommand.quickOpen.shortcut?.display
        }
    }

    /// The kit's palette rows: one flat line each, only the highlighted row filled, matched letters bold.
    private var menu: some View {
        AinkradCommandMenu(
            items: items,
            selection: Binding(get: { nil }, set: { if let item = $0 { activate(item) } }),
            icon: { $0.systemName },
            label: { $0.title },
            detail: { $0.detail },
            value: { $0.value },
            uppercased: false,
            emptyState: { AnyView(empty) },
            highlight: $highlight,
            handlesKeyPresses: true
        )
        .paletteRows()
        .matchedCharacters { $0.matched }
        .sections { $0.section }
    }

    private var placeholder: String {
        prefix == ">" ? "Run a command…" : prefix == ":" ? "Type a line number…" : prefix == "!" ? "Run a task…" : "Go to file…"
    }

    /// `.foot`: what ↵ does on the left, the other modes on the right — only what Forge does today.
    private var hints: (leading: [String], trailing: String) {
        switch prefix {
        case ":": (["↵ go to the line"], "⌫ files")
        case ">": (["↵ run"], "⌫ files")
        case "!": (["↵ run the task"], "⌫ files")
        default: (["↵ open"], ": line · > command · ! task")
        }
    }

    /// ">open" → (">", "open"); "side" → ("", "side").
    static func split(_ text: String) -> (prefix: String, query: String) {
        guard let first = text.first, first == ">" || first == ":" || first == "!" else { return ("", text) }
        return (String(first), String(text.dropFirst()))
    }

    private var empty: some View {
        AinkradEmptyState(
            icon: "magnifyingglass", title: "No matches",
            message: model.workspace == nil && prefix != ">"
                ? "Open a folder first, or type > for commands."
                : prefix.isEmpty && query.isEmpty ? "This folder has no files yet — type > for commands."
                : "Nothing matches “\(prefix + query)”.")
    }

    private func activateHighlighted() {
        guard let index = highlight, items.indices.contains(index) else { return }
        activate(items[index])
    }

    private func activate(_ item: PaletteItem) {
        switch item.payload {
        case .file(let path):
            model.palette = nil
            model.open(file: path, pinned: true)
            // The field that had focus leaves with the palette: hand it to the editor (E1D1 FD8).
            model.pendingFocus = true
        case .command(let command):
            model.noteCommandUsed(command)
            model.run(command)
        case .line(let line): model.goTo(line: line)
        case .task(let task): model.runTask(task)
        }
    }

    /// The rows for `query`. Static and pure, so modes and ranking are asserted directly.
    @MainActor static func items(for query: String, model: ForgeModel) -> [PaletteItem] {
        if query.hasPrefix(">") {
            // Matches first, then "Recently used" (VS Code's palette): with nothing typed, the recent ones lead.
            let typed = String(query.dropFirst())
            let available = model.availableCommands
            let recent = model.recentCommands.filter(available.contains).prefix(3)
            let matches = ForgeCommand.matching(typed, in: available)
            func item(_ command: ForgeCommand, section: String?) -> PaletteItem {
                PaletteItem(
                    id: "command:\(command.rawValue)", title: command.paletteTitle, systemName: "", detail: nil,
                    value: command.shortcut?.display, payload: .command(command), section: section,
                    matched: QuickOpen.matchedOffsets(typed, in: command.paletteTitle))
            }
            if typed.trimmingCharacters(in: .whitespaces).isEmpty {
                return recent.map { item($0, section: "Recently used") }
                    + matches.filter { !recent.contains($0) }.map { item($0, section: recent.isEmpty ? nil : "Commands") }
            }
            return matches.map { item($0, section: nil) }
                + recent.filter { !matches.contains($0) }.map { item($0, section: "Recently used") }
        }
        if query.hasPrefix("!") {
            let needle = Array(query.dropFirst().lowercased().filter { !$0.isWhitespace })
            return model.tasks.tasks
                .compactMap { task in
                    needle.isEmpty ? (task, 0) : QuickOpen.subsequenceScore(needle, in: "\(task.name) \(task.group)").map { (task, $0) }
                }
                .sorted { $0.1 > $1.1 }
                .map { task, _ in
                    PaletteItem(
                        id: "task:\(task.id)", title: task.name, systemName: "play", detail: task.group, value: task.shows,
                        payload: .task(task))
                }
        }
        if query.hasPrefix(":") {
            guard let line = Int(query.dropFirst().trimmingCharacters(in: .whitespaces)), line > 0,
                model.tabs.active != nil
            else { return [] }
            return [PaletteItem(id: "line", title: "Go to line \(line)", systemName: "arrow.right.to.line", detail: nil, payload: .line(line))]
        }
        guard let workspace = model.workspace else { return [] }
        // "Recently opened" first, then "Files" — each in rank order.
        let recent = Set(model.recentFiles)
        let ranked = QuickOpen.rank(query, files: workspace.files, recent: model.recentFiles)
        let ordered = ranked.filter { recent.contains($0.path) } + ranked.filter { !recent.contains($0.path) }
        return ordered.map { match in
            let name = (match.path as NSString).lastPathComponent
            let folder = (match.path as NSString).deletingLastPathComponent
            return PaletteItem(
                id: "file:\(match.path)", title: name,
                systemName: FileGlyph.glyph(name, isDirectory: false).0 == "◆" ? "diamond.fill" : "doc",
                detail: folder.isEmpty ? nil : folder, payload: .file(match.path),
                section: recent.contains(match.path) ? "Recently opened" : "Files",
                matched: QuickOpen.matchedOffsets(query, in: name))
        }
    }
}
