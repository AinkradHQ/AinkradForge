import AinkradAppKit
import SwiftUI

/// The sidebar's Search tab: query with its toggles, include / exclude globs, and results grouped by file.
/// Every control is a kit component, so under Liquid Glass each is Apple's own glass control.
struct SearchPanel: View {
    let model: ForgeModel
    let workspace: Workspace
    @FocusState private var queryFocused: Bool
    @Environment(\.ainkradSkin) private var skin

    private var search: SearchModel { model.search }

    var body: some View {
        @Bindable var search = model.search
        VStack(alignment: .leading, spacing: skin.size.s8) {
            AinkradSearchField(text: $search.query.text, placeholder: "Search")
                .focused($queryFocused)
            HStack(spacing: skin.size.s6) {
                AinkradButton(
                    title: "Replace", style: .ghost, icon: search.isReplaceOpen ? "chevron.down" : "chevron.right"
                ) { search.isReplaceOpen.toggle() }
                .fixedSize()
                Spacer(minLength: 0)
                // Symbols, not "Aa"/"ab": Neon upper-cases labels, which would make the two read the same.
                AinkradToggleButton(isOn: $search.query.matchCase, systemName: "textformat").help("Match case")
                AinkradToggleButton(isOn: $search.query.wholeWord, systemName: "text.word.spacing").help("Whole word")
                AinkradToggleButton(isOn: $search.query.regex, systemName: "asterisk").help("Regular expression")
            }
            if search.isReplaceOpen {
                GlassField(label: "replace", text: $search.replacement, placeholder: search.query.regex ? "$1 for a group" : "with")
                HStack(spacing: skin.size.s6) {
                    AinkradToggleButton(isOn: $search.preserveCase, title: "Preserve case")
                        .help("isSelected → isActive, IsSelected → IsActive")
                    Spacer(minLength: 0)
                    AinkradButton(title: "Replace All", style: .primary) { search.confirmingReplaceAll = true }
                        .fixedSize()
                        .disabled(search.results.isEmpty)
                        .help("Replace every match below (⌥⌘↵)")
                }
            }
            GlassField(label: "include", text: $search.include, placeholder: "Sources/**, *.swift")
            GlassField(label: "exclude", text: $search.exclude, placeholder: ".build, *.min.js")
            summary
            results
        }
        .onAppear { queryFocused = true }
        .onChange(of: model.searchFocusRequest) { _, _ in queryFocused = true }
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

    @ViewBuilder private var summary: some View {
        let text: String? =
            switch search.status {
            case .idle: nil
            case .searching: "Searching… \(search.lineCount) so far"
            case .done(let lines, let files, let ms, let capped):
                lines == 0
                    ? "No results · \(ms) ms"
                    : "\(capped ? "\(SearchModel.cap)+ results — refine the search" : "\(lines) results") in \(files) files · \(ms) ms"
            case .failed(let message): message
            case .references(let symbol, let lines, let files):
                "\(lines) \(lines == 1 ? "reference" : "references") to \(symbol) in \(files) \(files == 1 ? "file" : "files")"
            }
        if let text {
            Text(text)
                .font(skin.font(AinkradFontToken(sizeKey: "t11", monospacedDigits: true)))
                .foregroundStyle(skin.color(skin.text.muted))
                .padding(.horizontal, skin.size.s4)
        }
    }

    private var results: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(search.results) { file in
                    let folded = search.collapsed.contains(file.path)
                    ResultFileRow(
                        path: file.path, count: file.matches.count, isFolded: folded,
                        // While previewing a replace, the file is what is selected — not each of its lines,
                        // whose strike-through would vanish under a solid selection fill.
                        isSelected: search.isReplaceOpen && search.previewPath == file.path,
                        onReplace: search.isReplaceOpen ? { model.replace(in: file.path) } : nil
                    ) {
                        if folded { search.collapsed.remove(file.path) } else { search.collapsed.insert(file.path) }
                    }
                    if !folded {
                        ForEach(file.matches) { match in
                            ResultLineRow(
                                match: match,
                                isSelected: !search.isReplaceOpen
                                    && model.tabs.active == file.path && model.activeDocument?.cursor.line == match.line,
                                replacement: replacementText
                            ) {
                                if search.isReplaceOpen {
                                    search.previewPath = file.path
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

struct ResultFileRow: View {
    let path: String
    let count: Int
    let isFolded: Bool
    let isSelected: Bool
    /// Replace in this file (only while Replace is open).
    let onReplace: (() -> Void)?
    let toggle: () -> Void
    @State private var isHovered = false
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        let name = (path as NSString).lastPathComponent
        HStack(spacing: skin.size.s6) {
            Image(systemName: isFolded ? "chevron.right" : "chevron.down")
                .font(skin.font(AinkradFontToken(sizeKey: "t9", weight: "semibold")))
                .foregroundStyle(skin.color(skin.text.faint))
                .frame(width: skin.size.s10)
            Image(systemName: FileIcon.symbol(for: FileNode(path: path, name: name, isDirectory: false, children: [])))
                .font(skin.font(AinkradFontToken(sizeKey: "t11")))
                .foregroundStyle(FileIcon.tint(for: name, theme: theme) ?? skin.color(skin.text.faint))
            Text(name)
                .font(skin.font(AinkradFontToken(sizeKey: "t12", weight: "medium")))
                .foregroundStyle(theme.foreground.opacity(skin.opacity.o90))
                .lineLimit(1)
            Text((path as NSString).deletingLastPathComponent)
                .font(skin.font(AinkradFontToken(sizeKey: "t10")))
                .foregroundStyle(skin.color(skin.text.faint))
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: skin.size.s4)
            if let onReplace, isHovered {
                AinkradIconButton(systemName: "arrow.left.arrow.right", size: skin.size.s18, tooltip: "Replace in this file", action: onReplace)
            }
            AinkradBadge(text: "\(count)")
        }
        .padding(.vertical, skin.size.s4)
        .padding(.horizontal, skin.size.s6)
        .ainkradRowBackground(isSelected: isSelected, isHovered: isHovered)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: toggle)
        .help(path)
    }
}

private struct ResultLineRow: View {
    let match: LineMatch
    let isSelected: Bool
    /// While Replace is open: each match is shown struck through, followed by what it becomes.
    let replacement: ((String, NSRange) -> String)?
    let onClick: () -> Void
    let onDoubleClick: () -> Void
    @State private var isHovered = false
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradStatusColors) private var status

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: skin.size.s8) {
            Text("\(match.line)")
                .font(skin.font(AinkradFontToken(sizeKey: "t10", monospacedDigits: true)))
                .foregroundStyle(skin.color(skin.text.faint))
                .frame(minWidth: skin.size.s20, alignment: .trailing)
            Text(highlighted)
                .font(skin.font(AinkradFontToken(sizeKey: "t11", mono: "system")))
                .lineLimit(1)
        }
        .padding(.vertical, skin.size.s3)
        .padding(.leading, skin.size.s20)
        .padding(.trailing, skin.size.s6)
        .ainkradRowBackground(isSelected: isSelected, isHovered: isHovered)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2, perform: onDoubleClick)
        .simultaneousGesture(TapGesture().onEnded(onClick))
    }

    /// The line from its first match onwards (leading indentation dropped), matches on a warm wash.
    private var highlighted: AttributedString {
        let ns = match.text as NSString
        let start = min(match.ranges.first?.location ?? 0, max(0, ns.length))
        // From the end of the indentation, or 24 characters before the first match — whichever is later.
        let indent = ns.substring(to: start).prefix { $0 == " " || $0 == "\t" }.utf16.count
        let from = max(indent, start - 24)
        var out = AttributedString()
        var cursor = from
        for range in match.ranges where range.location >= cursor {
            out += plain(ns.substring(with: NSRange(location: cursor, length: range.location - cursor)))
            var hit = AttributedString(ns.substring(with: range))
            if let replacement {
                hit.foregroundColor = status.danger
                hit.strikethroughStyle = .single
                hit.backgroundColor = status.danger.opacity(skin.opacity.o16)
                var new = AttributedString(replacement(match.text, range))
                new.foregroundColor = status.success
                new.backgroundColor = status.success.opacity(skin.opacity.o16)
                out += hit
                out += new
            } else {
                hit.foregroundColor = theme.foreground
                hit.backgroundColor = status.warning.opacity(skin.opacity.o30)
                out += hit
            }
            cursor = range.location + range.length
        }
        out += plain(ns.substring(from: min(cursor, ns.length)))
        return out
    }

    private func plain(_ text: String) -> AttributedString {
        var part = AttributedString(text.replacingOccurrences(of: "\t", with: " "))
        part.foregroundColor = skin.color(skin.text.muted)
        return part
    }
}

/// A labelled text field. Under Liquid Glass it is a glass capsule like the kit's search field (whose glass
/// path it mirrors); elsewhere the kit's text field. Local only because `AinkradTextField` draws Apple's flat
/// rounded field under Glass — a glass-capsule text field in the kit is the proposal.
struct GlassField: View {
    let label: String
    @Binding var text: String
    let placeholder: String
    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        if #available(macOS 26, *), skin.usesNativeGlass {
            HStack(spacing: AinkradSpacing.sm) {
                Text(label)
                    .font(skin.font(AinkradFontToken(sizeKey: "t11")))
                    .foregroundStyle(.secondary)
                TextField(placeholder, text: $text)  // design-lint: allow raw-control kit gap: glass capsule text field
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, AinkradSpacing.md)
            .padding(.vertical, AinkradSpacing.sm)
            .glassEffect(.regular, in: .capsule)
        } else {
            AinkradTextField(text: $text, placeholder: "\(label.capitalized): \(placeholder)")
        }
    }
}

