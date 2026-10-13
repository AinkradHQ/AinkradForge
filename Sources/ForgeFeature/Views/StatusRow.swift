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
            } else if !workspace.isLoading {
                Text("no git").foregroundStyle(skin.color(skin.text.faint)).help("Not a git repository")
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
/// (E1D1 FD33); "– –" (unknown) while the active file's server starts (E6).
private struct IssueCounts: View {
    let model: ForgeModel
    @Environment(\.ainkradStatusColors) private var status
    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        let known = model.languages.statuses.values.contains(.ready)
        if known || activeServerStarting {
            HStack(spacing: skin.size.s6) {
                Label(known ? "\(model.languages.errorCount)" : "–", systemImage: "xmark.octagon")
                    .foregroundStyle(model.languages.errorCount > 0 ? status.danger : skin.color(skin.text.muted))
                Label(known ? "\(model.languages.warningCount)" : "–", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(model.languages.warningCount > 0 ? status.warning : skin.color(skin.text.muted))
            }
            .contentShape(Rectangle())
            .onTapGesture { model.sideTab = .problems }
            .help("Show issues")
        }
    }

    private var activeServerStarting: Bool {
        guard let path = model.tabs.active, let (spec, _) = LanguageRegistry.server(for: path) else { return false }
        return model.languages.statuses[spec.id] == .starting
    }
}

/// The active file's language server and its state — or that it has none, or the server is missing (E1D1 FD33);
/// the menu lists every server the workspace uses. E6: a hollow ○ for no server, a spinner and the server's
/// progress while it starts or indexes, red with an inline Restart once it has stopped.
private struct ServerChip: View {
    let model: ForgeModel
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradStatusColors) private var status

    var body: some View {
        if let path = model.tabs.active, let (spec, _) = LanguageRegistry.server(for: path) {
            let state = model.languages.statuses[spec.id] ?? .notRunning
            let progress = model.languages.progress[spec.id]
            HStack(spacing: skin.size.s6) {
                AinkradMenuButton(items: items(spec)) {
                    HStack(spacing: skin.size.s4) {
                        if state == .starting || (state == .ready && progress != nil) {
                            AinkradSpinner(size: skin.size.s10)
                        } else if state == .notInstalled {
                            hollowDot
                        } else {
                            Circle().fill(color(state)).frame(width: skin.size.s6, height: skin.size.s6)
                        }
                        Text(label(spec, state, progress))
                    }
                }
                .help(Self.describe(state, spec: spec))
                if Self.isStopped(state) {
                    AinkradButton(title: "Restart", style: .ghost) { model.languages.restart(spec.id) }.fixedSize()
                }
            }
        } else if model.tabs.active != nil {
            HStack(spacing: skin.size.s4) {
                hollowDot
                Text("No language server")
            }
            .help("No language server covers this file: no issues, completion or hover here.")
        }
    }

    private var hollowDot: some View {
        Circle().strokeBorder(skin.color(skin.text.faint), lineWidth: skin.size.s1).frame(width: skin.size.s7, height: skin.size.s7)
    }

    private func label(_ spec: ServerSpec, _ state: ServerStatus, _ progress: String?) -> String {
        switch state {
        case .starting: "\(spec.command) starting\(progress.map { " · \($0.lowercased())" } ?? "")"
        case .notInstalled: "\(spec.command) not installed"
        case .failed: "\(spec.command) failed"
        case .crashed: "\(spec.command) stopped"
        case .ready, .notRunning: progress.map { "\(spec.command) · \($0.lowercased())" } ?? spec.command
        }
    }

    static func isStopped(_ state: ServerStatus) -> Bool {
        switch state {
        case .failed, .crashed: true
        default: false
        }
    }

    private func items(_ active: ServerSpec) -> [AinkradMenuItem] {
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
        items.append(AinkradMenuItem(title: "Set \(active.command) Path…", systemName: "folder") {
            if let path = ServerPathPicker.choose(active) { model.setServerPath(active.id, path) }
        })
        items.append(AinkradMenuItem(title: "Show \(active.command) Log", systemName: "doc.text") { model.showServerLog(active.id) })
        return items
    }

    private func color(_ state: ServerStatus) -> Color {
        switch state {
        case .ready: status.success
        case .starting: theme.accentSecondary
        case .failed, .crashed: status.danger
        case .notInstalled: status.warning
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
        case .crashed(let how): "stopped (\(how)), twice in 5 minutes"
        }
    }
}
