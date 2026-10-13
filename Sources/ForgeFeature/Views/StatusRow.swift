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
        .padding(.top, skin.size.s7)
        .padding(.bottom, skin.size.s9)
    }

    private func row(showsFormat: Bool) -> some View {
        HStack(spacing: skin.size.s14) {
            if let branch = workspace.branch {
                Text("⑂ \(branch)")
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
                IndentationMenu(model: model)
                StatusMenu(title: document.format.encoding.rawValue, items: TextFormat.Encoding.allCases.map { encoding in
                    AinkradMenuItem(title: "Save as \(encoding.rawValue)", systemName: encoding == document.format.encoding ? "checkmark" : nil) {
                        document.setEncoding(encoding)
                    }
                })
                StatusMenu(title: document.format.lineEnding.rawValue, items: TextFormat.LineEnding.allCases.map { ending in
                    AinkradMenuItem(title: "Convert to \(ending.rawValue)", systemName: ending == document.format.lineEnding ? "checkmark" : nil) {
                        document.convertLineEndings(to: ending)
                    }
                })
                Text(document.language.name)
            } else if showsFormat, model.activeDocument == nil, !workspace.isLoading {
                // No file open: what a new file gets (mockup 19 A).
                Text(TextFormat().encoding.rawValue)
                Text(TextFormat().lineEnding.rawValue)
            }
        }
    }
}

/// `Spaces: 4` / `Tab Size: 4` — the editor's indentation settings, changed from its menu.
private struct IndentationMenu: View {
    let model: ForgeModel

    var body: some View {
        let settings = model.editorSettings
        StatusMenu(
            title: settings.insertSpaces ? "Spaces: \(settings.tabWidth)" : "Tab Size: \(settings.tabWidth)",
            items: [true, false].map { spaces in
                AinkradMenuItem(title: spaces ? "Indent Using Spaces" : "Indent Using Tabs", systemName: settings.insertSpaces == spaces ? "checkmark" : nil) {
                    model.editorSettings.insertSpaces = spaces
                }
            } + [2, 4, 8].enumerated().map { index, width in
                let item = AinkradMenuItem(title: "Width \(width)", systemName: settings.tabWidth == width ? "checkmark" : nil) {
                    model.editorSettings.tabWidth = width
                }
                return index == 0 ? item.startingGroup() : item
            })
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
/// (E1D1 FD33); "– –" (unknown) while the active file's server starts or after it stopped (E6, E1D2 FD42).
private struct IssueCounts: View {
    let model: ForgeModel
    @Environment(\.ainkradStatusColors) private var status
    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        let known = model.languages.statuses.values.contains(.ready)
        if known || activeServerStarting || activeServerStopped {
            // A plain button, so Full Keyboard Access reaches it (E1D2 FD40).
            Button { model.sideTab = .problems } label: {  // design-lint: allow raw-control keyboard-reachable status item
                HStack(spacing: skin.size.s6) {
                    Text("⊗ \(known ? "\(model.languages.errorCount)" : "–")")
                        .foregroundStyle(known ? status.danger : skin.color(skin.text.muted))
                    Text("⚠ \(known ? "\(model.languages.warningCount)" : "–")")
                        .foregroundStyle(known ? status.warning : skin.color(skin.text.muted))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show issues")
        }
    }

    private var activeServerStarting: Bool { activeServerStatus == .starting }

    private var activeServerStopped: Bool { activeServerStatus.map(ServerChip.isStopped) ?? false }

    private var activeServerStatus: ServerStatus? {
        guard let path = model.tabs.active, let (spec, _) = LanguageRegistry.server(for: path) else { return nil }
        return model.languages.statuses[spec.id]
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
                            // The mockup's dot: 7 pt with a soft glow of its own colour.
                            Circle().fill(color(state)).frame(width: skin.size.s7, height: skin.size.s7)
                                .shadow(color: state == .ready ? color(state) : .clear, radius: skin.size.s4)
                        }
                        Text(label(spec, state, progress))
                        if let fraction = Self.fraction(progress), state == .starting || state == .ready {
                            ProgressMeter(fraction: fraction)
                        }
                    }
                }
                .help(Self.describe(state, spec: spec))
                if Self.isStopped(state) {
                    // An inline link, the bar's height (mockup 19 D), not a boxed button.
                    Button("Restart") { model.languages.restart(spec.id) }  // design-lint: allow raw-control inline status-bar link
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.accentSecondary)
                        .help("Restart \(spec.command)")
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
        case .starting: "\(spec.command) starting\(progress.map { " · \(Self.grouped($0).lowercased())" } ?? "")"
        case .notInstalled: "\(spec.command) not installed"
        case .failed: "\(spec.command) failed"
        case .crashed: "\(spec.command) stopped"
        case .ready, .notRunning: progress.map { "\(spec.command) · \(Self.grouped($0).lowercased())" } ?? spec.command
        }
    }

    /// "Indexing 412 / 1280" → "Indexing 412 / 1,280".
    static func grouped(_ progress: String) -> String {
        progress.split(separator: " ", omittingEmptySubsequences: false)
            .map { word in Int(word).map { $0.formatted(.number.grouping(.automatic)) } ?? String(word) }
            .joined(separator: " ")
    }

    /// How far "412 / 1280" is, when the server reports a count.
    static func fraction(_ progress: String?) -> Double? {
        let words = progress?.split(separator: " ") ?? []
        guard let slash = words.firstIndex(of: "/"), slash > 0, slash + 1 < words.count,
            let done = Double(words[slash - 1]), let total = Double(words[slash + 1]), total > 0
        else { return nil }
        return min(1, done / total)
    }

    static func isStopped(_ state: ServerStatus) -> Bool {
        switch state {
        case .failed, .crashed: true
        default: false
        }
    }

    private func items(_ active: ServerSpec) -> [AinkradMenuItem] {
        let used = LanguageRegistry.servers.filter { model.languages.statuses[$0.id] != nil }
        let items = used.map { spec in
            let state = model.languages.statuses[spec.id] ?? .notRunning
            // `● sourcekit-lsp — ready · Swift`: the dot for a running server, the language it serves.
            return AinkradMenuItem(
                title: "\(spec.command) — \(Self.describe(state, spec: spec)) · \(spec.language)",
                systemName: state == .ready ? "circle.fill" : nil) {}
        }
        // The actions after a gap (never a line).
        var actions = used.filter { model.languages.statuses[$0.id] != .notInstalled }.map { spec in
            AinkradMenuItem(title: "Restart \(spec.command)", systemName: nil) { model.languages.restart(spec.id) }
        }
        actions.append(AinkradMenuItem(title: "Set \(active.command) Path…", systemName: nil) {
            if let path = ServerPathPicker.choose(active) { model.setServerPath(active.id, path) }
        })
        actions.append(AinkradMenuItem(title: "Show \(active.command) Log", systemName: nil) { model.showServerLog(active.id) })
        actions[0] = actions[0].startingGroup()
        return items + actions
    }

    private func color(_ state: ServerStatus) -> Color {
        switch state {
        case .ready, .starting: theme.accentSecondary
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
        case .crashed(let how): "stopped: \(how), twice in 5 minutes"
        }
    }
}
