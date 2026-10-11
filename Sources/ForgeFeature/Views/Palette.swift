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

    private var panel: some View {
        VStack(alignment: .leading, spacing: skin.size.s8) {
            AinkradSearchField(text: $query, placeholder: placeholder)
                .focused($focused)
                .onSubmit(activateHighlighted)
                // ⌫ on an empty field leaves command / line mode for files, as in VS Code.
                .onKeyPress(.delete) {
                    guard query.isEmpty, !prefix.isEmpty else { return .ignored }
                    prefix = ""
                    return .handled
                }
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
            .frame(maxHeight: skin.size.s360)
            Text(hint)
                .font(skin.font(AinkradFontToken(sizeKey: "t11")))
                .foregroundStyle(skin.color(skin.text.faint))
                .padding(.horizontal, skin.size.s4)
        }
        .padding(skin.size.s12)
        .frame(width: skin.size.s560)
        .fixedSize(horizontal: false, vertical: true)
        .ainkradPanel()
        .onAppear {
            (prefix, query) = Self.split(start)
            focused = true
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
            handlesKeyPresses: true)
    }

    private var placeholder: String {
        prefix == ">" ? "Run a command…" : prefix == ":" ? "Type a line number…" : prefix == "!" ? "Run a task…" : "Go to file…"
    }

    private var hint: String {
        if prefix == ":" { return "↵ go to the line · ⌫ to search files" }
        if prefix == ">" || prefix == "!" { return "↵ run · ⌫ to search files" }
        return "↵ open · type > for commands · : for a line"
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
                ? "Open a folder first, or type > for commands." : "Nothing matches “\(prefix + query)”.")
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
        case .command(let command): model.run(command)
        case .line(let line): model.goTo(line: line)
        case .task(let task): model.runTask(task)
        }
    }

    /// The rows for `query`. Static and pure, so modes and ranking are asserted directly.
    @MainActor static func items(for query: String, model: ForgeModel) -> [PaletteItem] {
        if query.hasPrefix(">") {
            return ForgeCommand.matching(String(query.dropFirst()), in: model.availableCommands).map {
                PaletteItem(
                    id: "command:\($0.rawValue)", title: $0.title, systemName: $0.systemName,
                    detail: nil, value: $0.shortcut?.display, payload: .command($0))
            }
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
        return QuickOpen.rank(query, files: workspace.files, recent: model.recentFiles).map { match in
            let name = (match.path as NSString).lastPathComponent
            let folder = (match.path as NSString).deletingLastPathComponent
            return PaletteItem(
                id: "file:\(match.path)", title: name,
                systemName: FileIcon.symbol(for: FileNode(path: match.path, name: name, isDirectory: false, children: [])),
                detail: folder.isEmpty ? nil : folder, payload: .file(match.path))
        }
    }
}
