import AinkradAppKit
import AppKit
import ForgeLanguage
import SwiftUI

/// No workspace open (`.welcome`): ⚒, the name, open / new, the recent workspaces, and which language servers
/// this Mac has.
struct WelcomeView: View {
    let model: ForgeModel
    @State private var servers: (found: [String], missing: [String])?
    /// Clone Repository… while its dialog is up.
    @State private var clone: GitClone?
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        VStack(spacing: skin.size.s22) {
            Text("⚒")
                .font(skin.font(AinkradFontToken(size: skin.size.s46)))
                .foregroundStyle(theme.foreground)
                .shadow(color: theme.accentSecondary.opacity(skin.opacity.o35), radius: skin.size.s18)
            Text(skin.labelCased(ForgeApp.displayName))
                .font(skin.font(AinkradFontToken(size: skin.size.s22, weight: "semibold")))
                .tracking(skin.usesNativeGlass ? 0 : skin.size.s22 * 0.08)
            HStack(spacing: skin.size.s10) {
                AinkradButton(title: "Open Folder…  \(model.shortcut(for: .openFolder)?.display ?? "")", style: .primary) {
                    if let url = FolderPicker.choose() { model.request(.open(url)) }
                }
                .fixedSize()
                AinkradButton(title: "Clone Repository…", style: .secondary) { clone = GitClone(parent: cloneParent) }
                    .secondaryAccent().fixedSize()
                AinkradButton(title: "New File", style: .secondary, action: newFile).secondaryAccent().fixedSize()
            }
            if !recents.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text(skin.labelCased("Recent workspaces"))
                        .font(skin.font(AinkradFontToken(sizeKey: "t10", weight: "semibold")))
                        .tracking(skin.usesNativeGlass ? 0 : skin.size.s10 * 0.08)
                        .foregroundStyle(skin.color(skin.text.muted))
                        .padding(.top, skin.size.s8)
                        .padding(.horizontal, skin.size.s12)
                        .padding(.bottom, skin.size.s4)
                    ForEach(Array(recents.enumerated()), id: \.element.path) { index, recent in
                        RecentRow(recent: recent, isFirst: index == 0) { model.request(.open(URL(fileURLWithPath: $0))) }
                    }
                }
                .padding(skin.size.s6)
                // 620 (`.recents`), narrower with the window (E1D1 FD35).
                .frame(maxWidth: skin.size.s620)
                .modifier(RecentsSurface())
            }
            if let servers { serverLine(servers) }
        }
        .padding(skin.size.s40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ainkradModal(
            isPresented: Binding(get: { clone != nil }, set: { if !$0 { closeClone() } }), contentWidth: CloneDialog.width
        ) {
            if let clone {
                CloneDialog(clone: clone, opened: { url in
                    self.clone = nil
                    // The guarded way in (FD37), as Open Folder.
                    model.request(.open(url))
                }, close: closeClone)
            }
        }
        .task {
            let overrides = model.editorSettings.serverPaths
            servers = await Task.detached { LanguageHub.availability(overrides: overrides) }.value
        }
    }

    /// `Language servers found: sourcekit-lsp · gopls — pyright not found (Settings → Languages)`.
    private func serverLine(_ servers: (found: [String], missing: [String])) -> some View {
        let missing =
            servers.missing.isEmpty ? ""
            : " — \(servers.missing.count <= 2 ? servers.missing.joined(separator: " · ") : "\(servers.missing.count) others") not found (Settings → Languages)"
        return (Text("Language servers found: ")
            + Text(servers.found.isEmpty ? "none" : servers.found.joined(separator: " · ")).font(skin.font(AinkradFontToken(sizeKey: "t11", mono: "family")))
            + Text(missing))
            .font(skin.font(AinkradFontToken(sizeKey: "t11")))
            .foregroundStyle(skin.color(skin.text.faint))
            .multilineTextAlignment(.center)
            .frame(maxWidth: skin.size.s620)
    }

    /// No workspace yet: name the file, then open its folder (its repo, if it is in one) with the file showing.
    private func newFile() {
        let panel = NSSavePanel()
        panel.prompt = "Create"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Never truncates an existing file: one that is there is simply opened.
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try Data().write(to: url, options: .withoutOverwriting)
            } catch {
                model.notice = "Could not create \(url.lastPathComponent): \(error.localizedDescription)"
                return
            }
        }
        Task { await model.start(launch: url.path) }
    }

    /// Closing the dialog (Esc, the scrim, Cancel) stops a clone still running.
    private func closeClone() {
        clone?.cancel()
        clone = nil
    }

    /// Where a clone goes by default: beside the newest recent workspace, else the home folder.
    private var cloneParent: URL {
        recents.first.map { URL(fileURLWithPath: $0.path).deletingLastPathComponent() }
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// Recents whose folder still exists.
    private var recents: [ForgeDocument.Recent] {
        model.store.document.recents.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

/// `.recents.cut`: Neon's chamfered panel on `--fill-strong` with the cyan stroke; Glass's rounded fill.
private struct RecentsSurface: ViewModifier {
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    func body(content: Content) -> some View {
        let shape = skin.shape(cut: skin.usesNativeGlass ? skin.size.s12 : skin.cut.c8)
        content
            .background(shape.fill(skin.usesNativeGlass ? ForgeStyle.fill(skin, theme) : ForgeStyle.fillStrong(skin, theme)))
            .overlay(shape.strokeBorder(ForgeStyle.stroke(skin, theme), lineWidth: skin.size.s1))
    }
}

private struct RecentRow: View {
    let recent: ForgeDocument.Recent
    /// The newest one is highlighted, as the mockup's `.rr.on`.
    let isFirst: Bool
    /// Opens a folder: the recent itself or one of its worktrees.
    let open: (String) -> Void
    @State private var isHovered = false
    /// The repo's other worktrees, each its own workspace, with how many files each has changed.
    @State private var worktrees: [(path: String, branch: String, changed: Int)] = []
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: skin.size.s2) {
            // Plain buttons, so Full Keyboard Access reaches the recent and each worktree (E1D2 FD40).
            Button { open(recent.path) } label: {  // design-lint: allow raw-control keyboard-reachable row (kit has no row button)
                VStack(alignment: .leading, spacing: skin.size.s2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text((recent.path as NSString).lastPathComponent)
                            .font(skin.font(AinkradFontToken(sizeKey: "t13")))
                            .foregroundStyle(theme.foreground)
                        Spacer(minLength: skin.size.s10)
                        Text(Self.ago(recent.opened))
                            .font(skin.font(AinkradFontToken(sizeKey: "t11", mono: "family")))
                            .foregroundStyle(skin.color(skin.text.faint))
                    }
                    Text((recent.path as NSString).abbreviatingWithTildeInPath)
                        .font(skin.font(AinkradFontToken(sizeKey: "t11", mono: "family")))
                        .foregroundStyle(skin.color(skin.text.faint))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !worktrees.isEmpty {
                HStack(spacing: skin.size.s6) {
                    ForEach(worktrees.prefix(4), id: \.path) { tree in
                        Button { open(tree.path) } label: {  // design-lint: allow raw-control keyboard-reachable chip
                            AinkradBadge(text: "⑂ \(tree.branch)\(tree.changed > 0 ? " · \(tree.changed) changed" : "")", tint: theme.accentSecondary)
                        }
                        .buttonStyle(.plain)
                        .help(tree.path)
                    }
                    if worktrees.count > 4 {
                        Text("+\(worktrees.count - 4)")
                            .font(skin.font(AinkradFontToken(sizeKey: "t11", monospacedDigits: true)))
                            .foregroundStyle(skin.color(skin.text.faint))
                    }
                }
                .padding(.top, skin.size.s4)
            }
        }
        .padding(.vertical, skin.size.s9)
        .padding(.horizontal, skin.size.s12)
        .background(
            RoundedRectangle(cornerRadius: skin.size.s8, style: .continuous)
                .fill(isHovered || isFirst ? skin.color(skin.palette.white).opacity(skin.opacity.o05) : .clear))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { open(recent.path) }
        .task {
            let output = try? await Git(directory: URL(fileURLWithPath: recent.path)).run(["worktree", "list", "--porcelain"])
            // Compare resolved paths: git reports /private/var/… where the recent may say /var/….
            let resolved = { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
            var found: [(path: String, branch: String, changed: Int)] = []
            for tree in GitParse.worktrees(output ?? "") where resolved(tree.path) != resolved(recent.path) {
                let status = try? await Git(directory: URL(fileURLWithPath: tree.path)).run(["--no-optional-locks", "status", "--porcelain"])
                found.append((tree.path, tree.branch, status.map { $0.split(separator: "\n").count } ?? 0))
            }
            worktrees = found
        }
    }

    /// `2m ago`, `1h ago`, `yesterday`, `3d ago` — the mockup's short form.
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(Int(seconds / 60))m ago"
        case ..<86_400: return "\(Int(seconds / 3_600))h ago"
        case ..<172_800: return "yesterday"
        case ..<2_592_000: return "\(Int(seconds / 86_400))d ago"
        default: return date.formatted(date: .abbreviated, time: .omitted)
        }
    }
}
