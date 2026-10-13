import AinkradAppKit
import SwiftUI

/// The sidebar's Search tab: query with its toggles, include / exclude globs, and results grouped by file.
/// The fields follow the kit field (a glass capsule under Liquid Glass); the toggles sit inside the query field.
struct SearchPanel: View {
    let model: ForgeModel
    let workspace: Workspace
    @FocusState private var queryFocused: Bool
    @FocusState private var replaceFocused: Bool
    @Environment(\.ainkradSkin) private var skin

    private var search: SearchModel { model.search }

    var body: some View {
        @Bindable var search = model.search
        VStack(alignment: .leading, spacing: skin.size.s8) {
            AinkradSearchField(text: $search.query.text, placeholder: "Search", focus: $queryFocused).codeQuery().fieldHeight(skin.size.s28).chamfered().trailingAccessory {
                AinkradFieldToggle("Aa", isOn: $search.query.matchCase, help: "Match case")
                AinkradFieldToggle("⌶", isOn: $search.query.wholeWord, help: "Whole word")
                AinkradFieldToggle("✱", isOn: $search.query.regex, help: "Regular expression")
            }
            // "▸ Replace" gives way to the replace field (mockup 08); Esc in the field closes it again.
            if !search.isReplaceOpen {
                Button { search.isReplaceOpen = true } label: {  // design-lint: allow raw-control disclosure text (mockup .sexp)
                    Text("▸ Replace")
                        .font(skin.font(AinkradFontToken(sizeKey: "t11")))
                        .foregroundStyle(skin.color(skin.text.faint))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, skin.size.s2)
                .help("Show Replace")
            } else {
                AinkradSearchField(
                    text: $search.replacement, placeholder: search.query.regex ? "$1 for a group" : "Replace", focus: $replaceFocused
                // 42 pt round its 30 pt Replace All, as mockup 08 draws it.
                ).codeQuery().fieldHeight(skin.size.s42).chamfered().trailingAccessory {
                    AinkradFieldToggle("AB", isOn: $search.preserveCase, help: "Preserve case (isSelected → isActive, IsSelected → IsActive)")
                    AinkradButton(title: "Replace All", style: .primary) { search.confirmingReplaceAll = true }
                        .compact()
                        .buttonHeight(skin.size.s30)
                        .fixedSize()
                        .disabled(search.results.isEmpty)
                        .help(model.titled("Replace every match below", .replaceAll))
                }
                // Through the responder chain while the field has the keyboard — not an Esc claim the editor would lose.
                .onExitCommand { search.isReplaceOpen = false }
                .help("Esc hides Replace")
            }
            VStack(spacing: skin.size.s6) {
                AinkradTextField(text: $search.include, placeholder: "Sources/**, *.swift").leadingLabel("include").compact().fieldHeight(skin.size.s24).chamfered()
                AinkradTextField(text: $search.exclude, placeholder: ".build/**, *.min.js").leadingLabel("exclude").compact().fieldHeight(skin.size.s24).chamfered()
            }
            summary
            results
        }
        .onAppear { DispatchQueue.main.async { queryFocused = true } }  // see Palette's onAppear
        .onChange(of: model.searchFocusRequest) { _, _ in queryFocused = true }
        // Opened: the replace field takes the keyboard (a turn later, as on appear), so Esc closes it straight away.
        .onChange(of: search.isReplaceOpen) { _, open in
            if open { DispatchQueue.main.async { replaceFocused = true } } else { queryFocused = true }
        }
        .onChange(of: search.query) { _, _ in rerun() }
        .onChange(of: search.include) { _, _ in rerun() }
        .onChange(of: search.exclude) { _, _ in rerun() }
        .onChange(of: workspace.files) { _, _ in
            if case .references = search.status { return }
            if !search.query.text.isEmpty { rerun(delay: .milliseconds(600)) }
        }
    }

    private func rerun(delay: Duration = .milliseconds(250)) {
        model.search.schedule(root: workspace.root, files: workspace.files, buffers: model.unsavedBuffers, delay: delay)
    }

    /// "7 results in 4 files · 38 ms · respects .gitignore" — the timing part faint (mockup 07 `.ssum`).
    @ViewBuilder private var summary: some View {
        if let parts = summaryParts {
            (Text(parts.0).foregroundStyle(skin.color(skin.text.muted))
                + Text(parts.1).foregroundStyle(skin.color(skin.text.faint)))
                .font(skin.font(AinkradFontToken(sizeKey: "t11", monospacedDigits: true)))
                .lineLimit(1)
                .padding(.horizontal, skin.size.s2)
        }
    }

    private var summaryParts: (String, String)? {
        switch search.status {
        case .idle: return nil
        case .searching: return ("Searching… \(search.lineCount) so far", "")
        case .done(let lines, let files, let ms, let capped):
            let timing = " · \(ms) ms · respects .gitignore"
            if lines == 0 { return ("No results", timing) }
            if capped { return ("\(SearchModel.cap)+ results — refine the search", timing) }
            let place = "in \(files) \(files == 1 ? "file" : "files")"
            return search.isReplaceOpen
                ? ("Replace \(lines) \(lines == 1 ? "match" : "matches") \(place)", timing)
                : ("\(lines) \(lines == 1 ? "result" : "results") \(place)", timing)
        case .failed(let message): return (message, "")
        case .references(let symbol, let lines, let files):
            return ("\(lines) \(lines == 1 ? "reference" : "references") to \(symbol) in \(files) \(files == 1 ? "file" : "files")", "")
        }
    }

    private var results: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(search.results) { file in
                    let folded = search.collapsed.contains(file.path)
                    ResultFileRow(
                        path: file.path, count: file.matches.count, isFolded: folded,
                        // While previewing a replace, the clicked line is what is selected (mockup 08), else its file.
                        isSelected: search.isReplaceOpen && search.previewPath == file.path && search.previewLine == nil,
                        onReplace: search.isReplaceOpen ? { model.replace(in: file.path) } : nil,
                        onDismiss: { search.dismiss(file.path) }
                    ) {
                        if folded { search.collapsed.remove(file.path) } else { search.collapsed.insert(file.path) }
                    }
                    if !folded {
                        ForEach(file.matches) { match in
                            ResultLineRow(
                                match: match,
                                isSelected: search.isReplaceOpen
                                    ? search.previewPath == file.path && search.previewLine == match.line
                                    : model.tabs.active == file.path && model.activeDocument?.cursor.line == match.line,
                                replacement: replacementText,
                                action: search.isReplaceOpen
                                    ? RowAction(glyph: "⇄", help: "Replace this one") { model.replace(in: file.path, line: match.line) }
                                    : RowAction(glyph: "✕", help: "Dismiss") { search.dismiss(file.path, line: match.line) }
                            ) {
                                if search.isReplaceOpen {
                                    search.previewPath = file.path
                                    search.previewLine = match.line
                                } else {
                                    open(file.path, line: match.line, pinned: false)
                                }
                            } onDoubleClick: {
                                open(file.path, line: match.line, pinned: true)
                            }
                        }
                    }
                }
            }
        }
        .scrollIndicators(.never)
    }

    /// While Replace is open: what a match on a line becomes (capture groups and preserve case applied).
    private var replacementText: ((String, NSRange) -> String)? {
        guard search.isReplaceOpen, let regex = try? search.query.compile() else { return nil }
        let template = search.query.regex ? search.replacement : NSRegularExpression.escapedTemplate(for: search.replacement)
        let preserve = search.preserveCase
        return { line, range in
            guard let match = regex.firstMatch(in: line, range: range) else { return search.replacement }
            let piece = regex.replacementString(for: match, in: line, offset: 0, template: template)
            return preserve ? TextSearch.adaptCase(piece, to: (line as NSString).substring(with: range)) : piece
        }
    }

    private func open(_ path: String, line: Int, pinned: Bool) {
        model.open(file: path, pinned: pinned)
        model.pendingLine = line
    }
}
