import AinkradAppKit
import ForgeLanguage
import SwiftUI

/// The sidebar's Issues tab: every diagnostic the language servers report, grouped by file, worst first.
struct IssuesList: View {
    let model: ForgeModel
    @State private var filter: Filter = .all
    @State private var thisFileOnly = false
    @State private var folded: Set<String> = []
    @Environment(\.ainkradSkin) private var skin

    enum Filter: String, CaseIterable, Identifiable {
        // No "Info" segment: under Glass the kit's segmented picker is fixed-size and a fourth segment is
        // clipped in the sidebar. Information and hints still show under All.
        case all = "All", errors = "Errors", warnings = "Warnings"
        var id: String { rawValue }

        func admits(_ severity: Issue.Severity) -> Bool {
            switch self {
            case .all: true
            case .errors: severity == .error
            case .warnings: severity == .warning
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: skin.size.s8) {
            HStack(spacing: skin.size.s6) {
                AinkradSegmentedPicker(items: Filter.allCases, selection: $filter) { $0.rawValue }
                    .controlSize(.small)
                Spacer(minLength: 0)
                AinkradToggleButton(isOn: $thisFileOnly, systemName: "doc.text").help("This file only")
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
                                IssueRow(issue: issue) {
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

private struct IssueRow: View {
    let issue: Issue
    let open: () -> Void
    @State private var isHovered = false
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradStatusColors) private var status

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: skin.size.s8) {
            Image(systemName: IssueStyle.symbol(issue.severity))
                .font(skin.font(AinkradFontToken(sizeKey: "t11")))
                .foregroundStyle(IssueStyle.color(issue.severity, status: status, theme: theme))
            Text(issue.message)
                .font(skin.font(AinkradFontToken(sizeKey: "t12")))
                .foregroundStyle(theme.foreground.opacity(skin.opacity.o85))
                .lineLimit(3)
            Spacer(minLength: skin.size.s4)
            Text("\(issue.start.line + 1):\(issue.start.character + 1)")
                .font(skin.font(AinkradFontToken(sizeKey: "t10", monospacedDigits: true)))
                .foregroundStyle(skin.color(skin.text.faint))
        }
        .padding(.vertical, skin.size.s4)
        .padding(.leading, skin.size.s20)
        .padding(.trailing, skin.size.s6)
        .ainkradRowBackground(isSelected: false, isHovered: isHovered)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: open)
        .help(issue.source.map { "\(issue.message) — \($0)" } ?? issue.message)
    }
}

/// Severity glyphs and colours, shared by the Issues tab, the editor's underlines and the status bar.
enum IssueStyle {
    static func symbol(_ severity: Issue.Severity) -> String {
        switch severity {
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .information, .hint: "info.circle"
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
