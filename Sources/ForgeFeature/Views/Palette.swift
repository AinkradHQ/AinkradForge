import AinkradAppKit
import SwiftUI

/// One row of the palette, whichever mode it is in.
struct PaletteItem: Hashable, Identifiable {
    enum Payload: Hashable {
        case file(String)
        case command(ForgeCommand)
        case line(Int)
        case task(WorkspaceTask)
        /// A symbol's file and 1-based line.
        case symbol(path: String, line: Int)
        /// A workspace folder's absolute path.
        case workspace(String)
    }

    let id: String
    let title: String
    /// The row's text glyph (`◆`, `≡`, `▶`) — "" for none — and its hue (forge.css `.ic.*`; nil: the cyan accent).
    let glyph: String
    var hue: String? = nil
    /// A symbol's kind (`struct`, `func`), leading the row in the type hue in place of a glyph (mockup 02).
    var kind: String? = nil
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
/// nothing = files, `>` = commands, `:` = go to line, `@` = this file's symbols, `#` = the workspace's, `!` = tasks,
/// `~` = the recent workspaces (⌃⌘O).
struct Palette: View {
    let model: ForgeModel
    let start: String
    /// The mode's character ("", ">" or ":"), kept out of the field: macOS selects a focused field's text,
    /// so a prefilled ">" would be replaced by the first letter typed.
    @State private var prefix = ""
    @State private var query = ""
    @State private var highlight: Int?
    @FocusState private var focused: Bool
    /// Takes the key press that becomes the new shortcut while `model.rebinding` is set.
    @State private var recorder = NextKey()
    @Environment(\.ainkradPaneIsFocused) private var paneFocused
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
        .onChange(of: model.paletteSymbols) { _, _ in highlight = items.isEmpty ? nil : 0 }
        .task(id: symbolTask) { await model.loadPaletteSymbols(for: prefix + query) }
        .background { openKeys }
        .background { rebindKey }
        .onChange(of: paneFocused) { _, focused in recorder.paneFocused = focused }
        .onDisappear {
            recorder.stop()
            model.rebinding = nil
        }
    }

    private var items: [PaletteItem] {
        Self.items(for: prefix + query, model: model)
    }

    /// `.palette`: the bare query line (`⌕ sbrow` with the mode's keycap), the results, the footer.
    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: skin.size.s10) {
                Text(prefix == ">" ? "›" : prefix == "!" ? "▶" : prefix.isEmpty ? "⌕" : prefix)
                    .foregroundStyle(skin.color(skin.text.faint))
                // A bare field (the mockup's `.q`), not the kit's boxed search field.
                TextField(placeholder, text: $query)  // design-lint: allow raw-control the palette's bare query line
                    .textFieldStyle(.plain)
                    .foregroundStyle(theme.foreground)
                    .tint(theme.accentSecondary)
                    .focused($focused)
                    .onSubmit { activateHighlighted() }
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
            // Typing a mode character first switches mode.
            if prefix.isEmpty, let first = typed.first, Self.modes.contains(first) { (prefix, query) = Self.split(typed) }
            // Re-ranking moves rows: a highlight left at row 7 would point at a different file.
            highlight = items.isEmpty ? nil : 0
        }
        .onChange(of: prefix) { _, _ in highlight = items.isEmpty ? nil : 0 }
    }

    /// Symbols are fetched for this: the file's once per mode, the workspace's per query.
    private var symbolTask: String { prefix == "#" ? prefix + query : prefix + (model.tabs.active ?? "") }

    /// ⌘K on a command's row records a new shortcut for it (mockup 03's footer).
    @ViewBuilder private var rebindKey: some View {
        if prefix == ">" {
            Button("Rebind Shortcut") { rebindHighlighted() }  // design-lint: allow raw-control key-equivalent claim
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    /// The next key press becomes the highlighted command's shortcut — unless Ainkrad, macOS or another command
    /// has it (the toast says which, and recording goes on). Esc cancels; ⌫ puts the default back.
    private func rebindHighlighted() {
        guard let index = highlight, items.indices.contains(index), case .command(let command) = items[index].payload else { return }
        model.rebinding = command
        recorder.paneFocused = paneFocused
        recorder.listen(onRelease: { model.rebinding = nil }) { event in
            let bare = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
            if bare, event.keyCode == 53 {
                model.rebinding = nil
                return true
            }
            if bare, event.keyCode == 51 {
                model.rebind(command, to: nil)
                model.rebinding = nil
                return true
            }
            guard let shortcut = Shortcut(event: event) else { return false }
            if let why = model.rejection(of: shortcut, for: command) {
                model.notice = why
                return false
            }
            model.rebind(command, to: shortcut)
            model.rebinding = nil
            return true
        }
    }

    /// ⌘↵ opens the highlighted file or symbol in the split, ⌥↵ in a new tab group — key-equivalent claims, so
    /// they reach the palette while its field has the keyboard.
    @ViewBuilder private var openKeys: some View {
        if prefix.isEmpty || prefix == "@" || prefix == "#" {
            ZStack {
                Button("Open to the Side") { activateHighlighted(in: .split) }  // design-lint: allow raw-control key-equivalent claim
                    .keyboardShortcut(.return, modifiers: .command)
                Button("Open in a New Tab Group") { activateHighlighted(in: .newGroup) }  // design-lint: allow raw-control key-equivalent claim
                    .keyboardShortcut(.return, modifiers: .option)
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
    }

    /// The chord that opens this mode, as the query line's keycap.
    private var modeKeys: String? {
        switch prefix {
        case ">": model.shortcut(for: .commandPalette)?.display
        case ":": model.shortcut(for: .goToLine)?.display
        case "~": model.shortcut(for: .switchWorkspace)?.display
        case "!", "@", "#": nil
        default: model.shortcut(for: .quickOpen)?.display
        }
    }

    /// The kit's palette rows: one flat line each, only the highlighted row filled, matched letters bold.
    private var menu: some View {
        AinkradCommandMenu(
            items: items,
            selection: Binding(get: { nil }, set: { if let item = $0 { activate(item) } }),
            icon: { $0.glyph },
            label: { $0.title },
            detail: { $0.detail },
            value: { $0.value },
            uppercased: false,
            emptyState: { AnyView(empty) },
            highlight: $highlight,
            handlesKeyPresses: true
        )
        .paletteRows()
        // 23 pt: the system font draws ◆ small; this matches the mockup's ◆ by eye (02).
        .iconGlyphs(tint: { $0.hue.map(ForgeStyle.hue) }, size: 23)
        .kinds({ $0.kind }, tint: { _ in nil })
        .matchedCharacters { $0.matched }
        .sections { $0.section }
    }

    private var placeholder: String {
        switch prefix {
        case ">": "Run a command…"
        case ":": "Type a line number…"
        case "!": "Run a task…"
        case "@": "Go to a symbol in this file…"
        case "#": "Go to a symbol in the workspace…"
        case "~": "Switch to a workspace…"
        default: "Go to file…"
        }
    }

    /// `.foot`: what ↵ does on the left, the other modes on the right — only what Forge does today.
    private var hints: (leading: [String], trailing: String) {
        switch prefix {
        case ":": (["↵ go to the line"], "⌫ files")
        case ">" where model.rebinding != nil:
            (["Press the new shortcut for “\(model.rebinding?.paletteTitle ?? "")”"], "Esc cancel · ⌫ default")
        case ">": (["↵ run", "⌘K rebind shortcut"], "Commands come from Forge + installed Ainkrad apps")
        case "!": (["↵ run the task"], "⌫ files")
        case "~": (["↵ open the workspace"], "⌫ files")
        case "@", "#": (["↵ go to the symbol", "⌘↵ open to the side"], "⌫ files")
        default: (["↵ open", "⌘↵ open to the side", "⌥↵ open in a new tab group"], ": line · @ symbol · > command")
        }
    }

    /// The characters that pick a mode when typed first.
    static let modes: Set<Character> = [">", ":", "!", "@", "#", "~"]

    /// ">open" → (">", "open"); "side" → ("", "side").
    static func split(_ text: String) -> (prefix: String, query: String) {
        guard let first = text.first, modes.contains(first) else { return ("", text) }
        return (String(first), String(text.dropFirst()))
    }

    private var empty: some View {
        AinkradEmptyState(
            icon: "magnifyingglass", title: "No matches",
            message: prefix == "~" ? "No other workspaces yet — \(model.shortcut(for: .openFolder)?.display ?? "Open Folder…") opens a folder."
                : (prefix == "@" || prefix == "#") && model.paletteSymbols.note != nil ? model.paletteSymbols.note ?? ""
                : model.workspace == nil && prefix != ">"
                ? "Open a folder first, or type > for commands."
                : prefix.isEmpty && query.isEmpty ? "This folder has no files yet — type > for commands."
                : "Nothing matches “\(prefix + query)”.")
    }

    private func activateHighlighted(in target: PaletteTarget = .here) {
        guard let index = highlight, items.indices.contains(index) else { return }
        activate(items[index], in: target)
    }

    private func activate(_ item: PaletteItem, in target: PaletteTarget = .here) {
        switch item.payload {
        case .file(let path): model.openFromPalette(path, in: target)
        case .symbol(let path, let line): model.openFromPalette(path, line: line, in: target)
        case .command(let command):
            model.noteCommandUsed(command)
            model.run(command)
        case .line(let line): model.goTo(line: line)
        case .task(let task): model.runTask(task)
        case .workspace(let path):
            model.palette = nil
            model.request(.open(URL(fileURLWithPath: path)))
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
                    id: "command:\(command.rawValue)", title: command.paletteTitle, glyph: "",
                    // Run Task… names what it would run (mockup 03), from the workspace's Makefile / package.json.
                    detail: command == .runTask && !model.tasks.tasks.isEmpty
                        ? model.tasks.tasks.prefix(3).map(\.shows).joined(separator: " · ") : nil,
                    value: model.rebinding == command ? "…" : model.shortcut(for: command)?.display,
                    payload: .command(command), section: section,
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
                        id: "task:\(task.id)", title: task.name, glyph: "▶", detail: task.group, value: task.shows,
                        payload: .task(task))
                }
        }
        if query.hasPrefix("~") { return workspaceItems(String(query.dropFirst()), model: model) }
        if query.hasPrefix("@") { return symbolItems(String(query.dropFirst()), model: model) }
        if query.hasPrefix("#") { return symbolItems(String(query.dropFirst()), model: model, filter: false) }
        if query.hasPrefix(":") {
            guard let line = Int(query.dropFirst().trimmingCharacters(in: .whitespaces)), line > 0,
                model.tabs.active != nil
            else { return [] }
            return [PaletteItem(id: "line", title: "Go to line \(line)", glyph: "→", detail: nil, payload: .line(line))]
        }
        guard let workspace = model.workspace else { return [] }
        // "Recently opened" first, then "Files" — each in rank order.
        let recent = Set(model.recentFiles)
        let ranked = QuickOpen.rank(query, files: workspace.files, recent: model.recentFiles)
        let ordered = ranked.filter { recent.contains($0.path) } + ranked.filter { !recent.contains($0.path) }
        // Then a few of this file's symbols (the mockup's "Symbols · type @ to search only symbols").
        let symbols = query.trimmingCharacters(in: .whitespaces).isEmpty
            ? [] : symbolItems(query, model: model, section: "Symbols · type @ to search only symbols", limit: 3)
        return ordered.map { match in
            let name = (match.path as NSString).lastPathComponent
            let folder = (match.path as NSString).deletingLastPathComponent
            let (glyph, hue) = FileGlyph.glyph(name, isDirectory: false)
            return PaletteItem(
                id: "file:\(match.path)", title: name, glyph: glyph, hue: hue,
                detail: folder.isEmpty ? nil : folder, payload: .file(match.path),
                section: recent.contains(match.path) ? "Recently opened" : "Files",
                matched: QuickOpen.matchedOffsets(query, in: name))
        } + symbols
    }

    /// `~`: the workspace's other worktrees, then the recent workspaces (the welcome list, mockup 05) — the current
    /// one left out — ranked by what is typed.
    @MainActor static func workspaceItems(_ query: String, model: ForgeModel) -> [PaletteItem] {
        let here = model.workspace.map { $0.root.resolvingSymlinksInPath().path }
        let trees = (model.workspace?.worktrees ?? []).map { ($0.path, $0.branch, "⑂") }
        let recents = model.store.document.recents.map { ($0.path, ($0.path as NSString).lastPathComponent, "") }
        var seen = Set<String>()
        let all = (trees + recents).filter { path, _, _ in
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            return resolved != here && seen.insert(resolved).inserted
        }
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        return all
            .compactMap { entry in needle.isEmpty ? (entry, 0) : QuickOpen.subsequenceScore(needle, in: entry.1).map { (entry, $0) } }
            .enumerated().sorted { ($0.element.1, -$0.offset) > ($1.element.1, -$1.offset) }
            .map { _, ranked in
                let (path, title, glyph) = ranked.0
                return PaletteItem(
                    id: "workspace:\(path)", title: title, glyph: glyph,
                    detail: (path as NSString).abbreviatingWithTildeInPath, payload: .workspace(path),
                    matched: QuickOpen.matchedOffsets(query, in: title))
            }
    }
}
