import AinkradAppKit
import ForgeLanguage
import SwiftUI

/// The sidebar's Issues tab: every diagnostic the language servers report, grouped by file, worst first.
struct IssuesList: View {
    let model: ForgeModel
    @State private var filter: Filter = .all
    @State private var thisFileOnly = false
    @State private var folded: Set<String> = []
    /// The issue last opened from the list (`.hit.sel`).
    @State private var selected: String?
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradStatusColors) private var status

    enum Filter: String, CaseIterable, Identifiable {
        case all, errors, warnings, info
        var id: String { rawValue }

        func admits(_ severity: Issue.Severity) -> Bool {
            switch self {
            case .all: true
            case .errors: severity == .error
            case .warnings: severity == .warning
            case .info: severity == .information || severity == .hint
            }
        }

        /// `All 5`, `⊗ 2`, `⚠ 2`, `ⓘ 1` — the glyph in its severity's colour.
        func title(_ count: Int, status: AinkradStatusColors) -> Text {
            switch self {
            case .all: Text("All \(count)")
            case .errors: Text("⊗").foregroundColor(status.danger) + Text(" \(count)")
            case .warnings: Text("⚠").foregroundColor(status.warning) + Text(" \(count)")
            case .info: Text("ⓘ \(count)")
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: skin.size.s8) {
            // `.ifilter`: a chip per severity with its count, then "This file only" as a text toggle.
            HStack(spacing: skin.size.s6) {
                ForEach(Filter.allCases) { kind in
                    FilterChip(title: kind.title(count(kind), status: status), isOn: filter == kind) { filter = kind }
                }
                Spacer(minLength: 0)
                Button { thisFileOnly.toggle() } label: {  // design-lint: allow raw-control the mockup's text toggle
                    Text("This file only")
                        .font(skin.font(AinkradFontToken(sizeKey: "t11")))
                        .foregroundStyle(thisFileOnly ? theme.accentSecondary : skin.color(skin.text.faint))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(thisFileOnly ? .isSelected : [])
            }
            if groups.isEmpty {
                Text(emptyText)
                    .font(skin.font(AinkradFontToken(sizeKey: "t12")))
                    .foregroundStyle(skin.color(skin.text.faint))
                    .padding(skin.size.s6)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groups, id: \.path) { group in
                        let isFolded = folded.contains(group.path)
                        ResultFileRow(path: group.path, count: group.issues.count, isFolded: isFolded, isSelected: false, onReplace: nil) {
                            if isFolded { folded.remove(group.path) } else { folded.insert(group.path) }
                        }
                        if !isFolded {
                            ForEach(group.issues) { issue in
                                IssueRow(issue: issue, isSelected: selected == issue.id) {
                                    selected = issue.id
                                    model.open(file: issue.path, pinned: false)
                                    model.pendingLine = issue.start.line + 1
                                }
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }

    private func count(_ kind: Filter) -> Int {
        model.languages.allIssues.filter { kind.admits($0.severity) }.count
    }

    private var groups: [(path: String, issues: [Issue])] {
        let active = model.tabs.active
        return model.languages.issues
            .filter { !thisFileOnly || $0.key == active }
            .map { ($0.key, $0.value.filter { filter.admits($0.severity) }) }
            .filter { !$0.1.isEmpty }
            .sorted { ($0.1[0].severity, $0.0) < ($1.1[0].severity, $1.0) }
    }

    private var emptyText: String {
        // Not "No issues" when nothing could report one (E1D1 FD33).
        if let gap = model.activeServerGap, thisFileOnly || !model.languages.statuses.values.contains(.ready) { return gap }
        if model.languages.statuses.isEmpty { return "Open a file — its language server reports issues here." }
        return thisFileOnly ? "No issues in this file." : "No issues."
    }
}

/// `.hit.issue`: the severity glyph, the message (11.5 pt, wrapping), `line:col` in faint mono.
private struct IssueRow: View {
    let issue: Issue
    let isSelected: Bool
    let open: () -> Void
    @State private var isHovered = false
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradStatusColors) private var status

    var body: some View {
        // A plain button, so Full Keyboard Access can reach the issue (E1D1 FD34).
        Button(action: open) { label }  // design-lint: allow raw-control keyboard-reachable row (kit has no row button)
            .buttonStyle(.plain)
            .help(issue.source.map { "\(issue.message) — \($0)" } ?? issue.message)
    }

    private var label: some View {
        HStack(alignment: .firstTextBaseline, spacing: skin.size.s8) {
            Text(IssueStyle.glyph(issue.severity))
                .font(skin.font(AinkradFontToken(size: 11.5)))
                .foregroundStyle(issue.severity <= .warning ? IssueStyle.color(issue.severity, status: status, theme: theme) : skin.color(skin.text.faint))
            Text(issue.message)
                .font(skin.font(AinkradFontToken(size: 11.5)))
                .foregroundStyle(isSelected ? theme.foreground : skin.color(skin.text.muted))
                .lineSpacing(skin.size.s2)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(issue.start.line + 1):\(issue.start.character + 1)")
                .font(skin.font(AinkradFontToken(sizeKey: "t10", mono: "family")))
                .foregroundStyle(skin.color(skin.text.faint))
        }
        .padding(.vertical, skin.size.s3)
        .padding(.leading, skin.size.s22)
        .padding(.trailing, skin.size.s8)
        .ainkradRowBackground(isSelected: isSelected, isHovered: isHovered, style: .fill)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

/// `.ifilter .chip`: a small chamfered chip (Neon) or capsule (Glass), filled with the accent when on.
private struct FilterChip: View {
    let title: Text
    let isOn: Bool
    let action: () -> Void
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        let shape = skin.shape(cut: skin.usesNativeGlass ? skin.size.s10 : skin.cut.c4)
        Button(action: action) {  // design-lint: allow raw-control the mockup's severity chip
            title
                .font(skin.font(AinkradFontToken(sizeKey: "t11", monospacedDigits: true)))
                .foregroundStyle(isOn ? theme.foreground : skin.color(skin.text.muted))
                .padding(.vertical, skin.size.s2)
                .padding(.horizontal, skin.size.s8)
                .background(shape.fill(isOn ? theme.accentPrimary.opacity(skin.opacity.o35) : ForgeStyle.fillStrong(skin, theme)))
                .overlay(shape.strokeBorder(ForgeStyle.stroke(skin, theme), lineWidth: skin.size.s1))
                .fixedSize()
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Severity glyphs and colours, shared by the Issues tab, the editor's underlines and the status bar.
enum IssueStyle {
    /// The mockups' text glyphs: `⊗` `⚠` `ⓘ`.
    static func glyph(_ severity: Issue.Severity) -> String {
        switch severity {
        case .error: "⊗"
        case .warning: "⚠"
        case .information, .hint: "ⓘ"
        }
    }

    static func color(_ severity: Issue.Severity, status: AinkradStatusColors, theme: HostThemeTokens) -> Color {
        switch severity {
        case .error: status.danger
        case .warning: status.warning
        case .information, .hint: theme.accentSecondary
        }
    }
}
