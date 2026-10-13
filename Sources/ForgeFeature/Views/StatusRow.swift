import AinkradAppKit
import ForgeLanguage
import SwiftUI

/// Branch, cursor, line endings, encoding and language. Language-server state joins with E5.
struct StatusRow: View {
    let model: ForgeModel
    let workspace: Workspace
    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        // Too narrow for everything: the file's line endings, encoding and language go first, so the counts,
        // branch and server keep their room (E1D1 FD28).
        ViewThatFits(in: .horizontal) {
            row(showsFormat: true)
            row(showsFormat: false)
        }
        .font(skin.font(AinkradFontToken(sizeKey: "t11", monospacedDigits: true)))
        .foregroundStyle(skin.color(skin.text.muted))
        .lineLimit(1)
        .padding(.horizontal, skin.size.s18)
        .padding(.vertical, skin.size.s8)
    }

    private func row(showsFormat: Bool) -> some View {
        HStack(spacing: skin.size.s14) {
            if let branch = workspace.branch {
                Label(branch, systemImage: "arrow.triangle.branch")
            }
            IssueCounts(model: model).fixedSize()
            ServerChip(model: model)
            OutsideChangesButton(model: model)
            if workspace.isLoading { AinkradSpinner() }
            Spacer(minLength: skin.size.s8)
            if let document = model.activeDocument, document.state == .ready {
                Text("Ln \(document.cursor.line), Col \(document.cursor.column)")
            }
            if showsFormat, let document = model.activeDocument, document.state == .ready {
                StatusMenu(title: document.format.lineEnding.rawValue, items: TextFormat.LineEnding.allCases.map { ending in
                    AinkradMenuItem(title: "Convert to \(ending.rawValue)", systemName: ending == document.format.lineEnding ? "checkmark" : nil) {
                        document.convertLineEndings(to: ending)
                    }
                })
                StatusMenu(title: document.format.encoding.rawValue, items: TextFormat.Encoding.allCases.map { encoding in
                    AinkradMenuItem(title: "Save as \(encoding.rawValue)", systemName: encoding == document.format.encoding ? "checkmark" : nil) {
                        document.setEncoding(encoding)
                    }
                })
                Text(document.language.name)
            }
        }
    }
}

/// A status-bar item that opens a pull-down menu — plain text until hovered, like the rest of the bar.
private struct StatusMenu: View {
    let title: String
    let items: [AinkradMenuItem]
    @State private var isHovered = false
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        AinkradMenuButton(items: items) {
            Text(title)
                .foregroundStyle(isHovered ? theme.foreground : skin.color(skin.text.muted))
                .onHover { isHovered = $0 }
        }
    }
}

/// ⊗ errors ⚠ warnings — opens the Issues tab. Only once a server runs: "0 0" with none would read as clean
/// (E1D1 FD33).
private struct IssueCounts: View {
    let model: ForgeModel
    @Environment(\.ainkradStatusColors) private var status
    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        if model.languages.statuses.values.contains(.ready) {
            HStack(spacing: skin.size.s6) {
                Label("\(model.languages.errorCount)", systemImage: "xmark.octagon")
                    .foregroundStyle(model.languages.errorCount > 0 ? status.danger : skin.color(skin.text.muted))
                Label("\(model.languages.warningCount)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(model.languages.warningCount > 0 ? status.warning : skin.color(skin.text.muted))
            }
            .contentShape(Rectangle())
            .onTapGesture { model.sideTab = .problems }
            .help("Show issues")
        }
    }
}

/// The active file's language server and its state — or that it has none, or the server is missing (E1D1 FD33);
/// the menu lists every server the workspace uses.
private struct ServerChip: View {
    let model: ForgeModel
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradStatusColors) private var status

    var body: some View {
        if let path = model.tabs.active, let (spec, _) = LanguageRegistry.server(for: path) {
            let state = model.languages.statuses[spec.id] ?? .notRunning
            AinkradMenuButton(items: items) {
                HStack(spacing: skin.size.s4) {
                    Circle().fill(color(state)).frame(width: skin.size.s6, height: skin.size.s6)
                    Text(model.activeServerGap == nil ? spec.command : "\(spec.command) \(state == .notInstalled ? "not installed" : "failed")")
                }
            }
            .help(Self.describe(state, spec: spec))
        } else if model.tabs.active != nil {
            Text("No language server").help("No language server covers this file: no issues, completion or hover here.")
        }
    }

    private var items: [AinkradMenuItem] {
        let used = LanguageRegistry.servers.filter { model.languages.statuses[$0.id] != nil }
        var items = used.map { spec in
            let state = model.languages.statuses[spec.id] ?? .notRunning
            return AinkradMenuItem(title: "\(spec.command) — \(Self.describe(state, spec: spec))", systemName: nil) {}
        }
        for spec in used where model.languages.statuses[spec.id] != .notInstalled {
            items.append(AinkradMenuItem(title: "Restart \(spec.command)", systemName: "arrow.clockwise") {
                model.languages.restart(spec.id)
            })
        }
        return items
    }

    private func color(_ state: ServerStatus) -> Color {
        switch state {
        case .ready: status.success
        case .starting: theme.accentSecondary
        case .failed, .notInstalled: status.warning
        case .notRunning: skin.color(skin.text.faint)
        }
    }

    static func describe(_ state: ServerStatus, spec: ServerSpec) -> String {
        switch state {
        case .ready: "ready"
        case .starting: "starting…"
        case .notRunning: "not running"
        case .notInstalled: "not installed — \(spec.installHint)"
        case .failed(let why): "failed: \(why)"
        }
    }
}
