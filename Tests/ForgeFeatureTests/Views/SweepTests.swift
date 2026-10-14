import AinkradAppKit
import AppKit
import SwiftUI
import XCTest

@testable import ForgeFeature

/// Forge's screens under Neon and Liquid Glass, written as `<dir>/<name>-neon.png` / `-glass.png` for
/// screen-by-screen review. A tool, not a check: it runs only with AINKRAD_SWEEP_DIR and AINKRAD_THEMES_DIR
/// (the catalog's `themes/`) set. Live window captures — off-screen `cacheDisplay` cannot draw Liquid Glass.
/// The workspace is a throwaway git repo shaped like the mockups, so no real code leaks.
///
/// XCTest, not Swift Testing: a Swift Testing `@MainActor` test runs as a job on the main dispatch queue, so
/// the editor's own main-queue work (highlighting, its transparent background) never runs while it waits.
@MainActor
final class SweepTests: XCTestCase {
    func testShootE2Screens() throws {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["AINKRAD_SWEEP_DIR"], let themes = env["AINKRAD_THEMES_DIR"] else {
            throw XCTSkip("set AINKRAD_SWEEP_DIR and AINKRAD_THEMES_DIR to shoot the screens")
        }
        let glass = try SweepSupport.glassSkin(themes: URL(fileURLWithPath: themes))
        SweepSupport.registerHostFonts()
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let repo = try SampleRepo.make()
        defer { try? FileManager.default.removeItem(at: repo.deletingLastPathComponent()) }

        // Screen 1: the window, a file open, the tree expanded down to it.
        let window = try SweepSupport.model(opening: repo)
        for folder in ["Sources", "Sources/Ainkrad", "Sources/Ainkrad/Features", "Sources/Ainkrad/Features/Sidebar"] {
            window.toggle(folder: folder)
        }
        window.open(file: "Sources/Ainkrad/Features/Sidebar/SidebarView.swift", pinned: true)
        window.open(file: "project.yml", pinned: true)
        window.open(file: "Sources/Ainkrad/Features/Sidebar/SidebarRow.swift", pinned: true)
        try SweepSupport.waitUntilLoaded(window)

        // The Changes tab, with a preview tab open.
        let changes = try SweepSupport.model(opening: repo)
        changes.sideTab = .changes
        changes.open(file: "Sources/Ainkrad/Features/Sidebar/SidebarRow.swift", pinned: false)
        try SweepSupport.waitUntilLoaded(changes)

        // Closing a tab with unsaved changes.
        let closing = try SweepSupport.model(opening: repo)
        closing.open(file: "Sources/Ainkrad/Features/Sidebar/SidebarRow.swift", pinned: true)
        try SweepSupport.waitUntilLoaded(closing)
        closing.activeDocument?.storage.mutableString.append("\n")
        closing.didEdit("Sources/Ainkrad/Features/Sidebar/SidebarRow.swift")
        closing.close("Sources/Ainkrad/Features/Sidebar/SidebarRow.swift")

        // Screens 2 and 3: quick open and the command palette over the window.
        let quick = try SweepSupport.model(opening: repo)
        for folder in ["Sources", "Sources/Ainkrad", "Sources/Ainkrad/Features", "Sources/Ainkrad/Features/Sidebar"] {
            quick.toggle(folder: folder)
        }
        quick.open(file: "Sources/Ainkrad/Features/Sidebar/SidebarRow.swift", pinned: true)
        try SweepSupport.waitUntilLoaded(quick)
        quick.palette = "sbrow"
        let commands = try SweepSupport.model(opening: repo)
        commands.open(file: "Sources/Ainkrad/Features/Sidebar/SidebarRow.swift", pinned: true)
        try SweepSupport.waitUntilLoaded(commands)
        commands.palette = ">"

        // Screen 4: the split editor — SidebarRow left, SidebarModel previewed right; and stacked.
        let split = try SweepSupport.model(opening: repo)
        for folder in ["Sources", "Sources/Ainkrad", "Sources/Ainkrad/Features", "Sources/Ainkrad/Features/Sidebar"] {
            split.toggle(folder: folder)
        }
        split.open(file: "Sources/Ainkrad/Features/Sidebar/SidebarView.swift", pinned: true)
        split.open(file: "Sources/Ainkrad/Features/Sidebar/SidebarRow.swift", pinned: true)
        split.splitEditor(stacked: false)
        split.open(file: "Sources/Ainkrad/Features/Sidebar/SidebarModel.swift", pinned: false)
        split.focus(pane: 0)
        SweepSupport.spin(until: 3) { split.documents.values.allSatisfy { $0.state == .ready } }
        let stacked = try SweepSupport.model(opening: repo)
        stacked.open(file: "Sources/Ainkrad/Features/Sidebar/SidebarRow.swift", pinned: true)
        stacked.splitEditor(stacked: true)
        stacked.open(file: "project.yml", pinned: true)
        SweepSupport.spin(until: 3) { stacked.documents.values.allSatisfy { $0.state == .ready } }

        // Screen 6: renaming a row in place, and naming a new file in a folder.
        let renaming = try SweepSupport.model(opening: repo)
        renaming.open(file: "Sources/Ainkrad/Features/Sidebar/SidebarRow.swift", pinned: true)
        try SweepSupport.waitUntilLoaded(renaming)
        renaming.beginRename("Sources/Ainkrad/Features/Sidebar/SidebarGlassCapsule.swift")
        let creating = try SweepSupport.model(opening: repo)
        creating.open(file: "Sources/Ainkrad/Features/Sidebar/SidebarRow.swift", pinned: true)
        try SweepSupport.waitUntilLoaded(creating)
        creating.beginNew(folder: false, in: "Sources/Ainkrad/Features/Sidebar")

        // E3: a file changed outside Forge while it had unsaved edits, shown with its CRLF / UTF-16 format.
        let conflicted = try SweepSupport.model(opening: repo)
        let crlf = repo.appendingPathComponent("Sources/Ainkrad/Core/Log.swift")
        try (Data([0xFF, 0xFE]) + "import os\r\n\r\nlet log = Logger()\r\n".data(using: .utf16LittleEndian)!).write(to: crlf)
        conflicted.open(file: "Sources/Ainkrad/Core/Log.swift", pinned: true)
        try SweepSupport.waitUntilLoaded(conflicted)
        conflicted.activeDocument?.storage.mutableString.append("\n")
        conflicted.didEdit("Sources/Ainkrad/Core/Log.swift")
        try (Data([0xFF, 0xFE]) + "import os\r\n".data(using: .utf16LittleEndian)!).write(to: crlf)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: crlf.path)
        SweepSupport.spin(until: 3) { conflicted.activeDocument?.conflict != nil }

        // E3: editor settings applied — larger font, minimap and invisibles on.
        let tuned = try SweepSupport.model(opening: repo)
        var settings = EditorSettings()
        settings.fontSize = 15
        settings.showMinimap = true
        settings.showInvisibles = true
        tuned.editorSettings = settings
        tuned.open(file: "Sources/Ainkrad/Features/Sidebar/SidebarRow.swift", pinned: true)
        try SweepSupport.waitUntilLoaded(tuned)

        // E4 screen 7: search across files, a result opened at its line.
        let searching = try SweepSupport.model(opening: repo)
        searching.showSearch()
        searching.search.query.text = "isSelected"
        searching.search.include = "Sources/**, Tests/**"
        searching.search.schedule(root: repo, files: searching.workspace?.files ?? [], buffers: [:], delay: .zero)
        SweepSupport.spin(until: 5) { if case .done = searching.search.status { true } else { false } }
        searching.open(file: "Sources/Ainkrad/Features/Sidebar/SidebarRow.swift", pinned: false)
        searching.pendingLine = 19
        try SweepSupport.waitUntilLoaded(searching)

        // E4 screen 8: replace with a preview of one file's changes.
        let replacing = try SweepSupport.model(opening: repo)
        replacing.showSearch()
        replacing.search.query.text = "isSelected"
        replacing.search.isReplaceOpen = true
        replacing.search.replacement = "isActive"
        replacing.rerunSearch()
        SweepSupport.spin(until: 5) { if case .done = replacing.search.status { true } else { false } }
        replacing.search.previewPath = "Sources/Ainkrad/Features/Sidebar/SidebarRow.swift"
        replacing.search.previewLine = 19

        // E5 screen 9: a real sourcekit-lsp's issues — the Issues tab, underlines, status-bar counts and chip.
        let diagnosed = try SweepSupport.model(opening: repo)
        let broken = "Sources/Ainkrad/Features/Sidebar/SidebarBadge.swift"
        try """
            import SwiftUI

            struct SidebarBadge: View {
                let count: Int
                var body: some View {
                    let label: String = count
                    Text(label).foregroundStyle(.secondary).padding(missingInset)
                }
            }

            """.write(to: repo.appendingPathComponent(broken), atomically: true, encoding: .utf8)
        diagnosed.sideTab = .problems
        diagnosed.open(file: broken, pinned: true)
        try SweepSupport.waitUntilLoaded(diagnosed)
        SweepSupport.spin(until: 30) { diagnosed.languages.issues[broken]?.count ?? 0 >= 2 }

        // E5 screen 9: the hover card on `count` — its issue, then sourcekit's signature. The rect is where the
        // word sits in the sweep's layout (the editor reports the real one).
        let hovering = try SweepSupport.model(opening: repo)
        hovering.open(file: broken, pinned: true)
        try SweepSupport.waitUntilLoaded(hovering)
        SweepSupport.spin(until: 30) { hovering.languages.issues[broken] != nil }
        let badgeText = try String(contentsOf: repo.appendingPathComponent(broken), encoding: .utf8)
        let countOffset = (badgeText as NSString).range(of: "= count").location + 2
        Task { await hovering.hover(pane: 0, path: broken, at: (countOffset, CGRect(x: 285, y: 113, width: 39, height: 22))) }
        SweepSupport.spin(until: 15) { hovering.hover != nil }

        // E5 screen 10: signature help inside a call, on its second argument.
        let typing = try SweepSupport.model(opening: repo)
        let bump = "Sources/Ainkrad/Features/Sidebar/Bump.swift"
        let call = "func bump(_ n: Int, by step: Int) -> Int { n + step }\n\nlet a = bump(1, "
        try call.write(to: repo.appendingPathComponent(bump), atomically: true, encoding: .utf8)
        typing.open(file: bump, pinned: true)
        try SweepSupport.waitUntilLoaded(typing)
        SweepSupport.spin(until: 30) { typing.languages.statuses["sourcekit-lsp"] == .ready }
        Task { await typing.signature(pane: 0, path: bump, at: ((call as NSString).length, CGRect(x: 192, y: 47, width: 1, height: 22))) }
        SweepSupport.spin(until: 15) { typing.signature != nil }

        // ⇧F12 on `count`: the sample repo is no package, so sourcekit-lsp has no index and finds no references —
        // the whole-word search stands in and says so.
        let referencing = try SweepSupport.model(opening: repo)
        referencing.open(file: broken, pinned: true)
        try SweepSupport.waitUntilLoaded(referencing)
        SweepSupport.spin(until: 30) { referencing.languages.statuses["sourcekit-lsp"] == .ready }
        referencing.activeDocument?.cursor = (4, 13)
        referencing.findReferences()
        SweepSupport.spin(until: 15) { if case .done = referencing.search.status { true } else { false } }

        // E5 screen 11: F2 on `count` — the rename field with its reach; and ↵'s preview of renaming it to `value`.
        let renamingSymbol = try SweepSupport.model(opening: repo)
        renamingSymbol.open(file: broken, pinned: true)
        try SweepSupport.waitUntilLoaded(renamingSymbol)
        SweepSupport.spin(until: 30) { renamingSymbol.languages.issues[broken] != nil }
        renamingSymbol.activeDocument?.cursor = (4, 13)
        renamingSymbol.activeDocument?.caretRect = CGRect(x: 145, y: 69, width: 1, height: 22)
        renamingSymbol.beginRename()
        SweepSupport.spin(until: 15) { renamingSymbol.rename?.places != nil }
        renamingSymbol.rename?.newName = "value"
        let previewing = try SweepSupport.model(opening: repo)
        previewing.open(file: broken, pinned: true)
        try SweepSupport.waitUntilLoaded(previewing)
        SweepSupport.spin(until: 30) { previewing.languages.issues[broken] != nil }
        previewing.activeDocument?.cursor = (4, 13)
        previewing.beginRename()
        previewing.rename?.newName = "value"
        previewing.commitRename(preview: true)
        SweepSupport.spin(until: 15) { previewing.pendingEdit != nil }

        // E6 screen 12: the terminal drawer — a shell, and a finished command in its own tab, shown.
        let terminal = try SweepSupport.model(opening: repo)
        terminal.open(file: "Sources/Ainkrad/Features/Sidebar/SidebarRow.swift", pinned: true)
        try SweepSupport.waitUntilLoaded(terminal)
        terminal.terminals.add()
        terminal.terminals.add(command: "git status --short && git log --oneline -3", title: "git status")

        // E6 screen 13: the gutter's change marks against HEAD, a peek at one change, blame on the caret's line.
        let gitting = try SweepSupport.model(opening: repo)
        let row = "Sources/Ainkrad/Features/Sidebar/SidebarRow.swift"
        gitting.open(file: row, pinned: true)
        try SweepSupport.waitUntilLoaded(gitting)
        // In the buffer too: one line changed, one removed — so all three kinds of mark show.
        let rowDocument = try XCTUnwrap(gitting.activeDocument)
        let edited = rowDocument.storage.string
            .replacingOccurrences(of: "Spacer()", with: "Spacer(minLength: skin.size.s4)")
            .replacingOccurrences(of: "            Text(thread.title).lineLimit(1)\n", with: "")
        rowDocument.storage.replaceCharacters(in: NSRange(location: 0, length: rowDocument.storage.length), with: edited)
        gitting.didEdit(row)
        SweepSupport.spin(until: 10) { (gitting.git.hunks[row]?.count ?? 0) >= 3 }
        let hunks = gitting.git.hunks[row] ?? []
        if let changed = hunks.firstIndex(where: { $0.oldCount > 0 && $0.newCount > 0 }) {
            gitting.peekChange(
                pane: 0, path: row, hunk: changed,
                rect: CGRect(x: 52, y: Double(hunks[changed].newStart - 1) * 25.9 + 4, width: 8, height: 25))
        }
        gitting.activeDocument?.cursor = (7, 9)
        gitting.activeDocument?.caretRect = CGRect(x: 120, y: 6 * 25.9 + 4, width: 1, height: 25)
        gitting.activeDocument?.caretLineEnd = 300
        gitting.toggleBlame()
        SweepSupport.spin(until: 10) { gitting.git.blame != nil }

        // E6 screen 14: the drawer's Tasks tab — Makefile targets and a package's scripts.
        try "build: generate ; xcodebuild\ntest: ; xcodebuild test\ngenerate: ; xcodegen\nabi-check: ; scripts/abi.sh\n"
            .write(to: repo.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("apps/site"), withIntermediateDirectories: true)
        try #"{"scripts": {"dev": "next dev", "lint": "eslint ."}}"#
            .write(to: repo.appendingPathComponent("apps/site/package.json"), atomically: true, encoding: .utf8)
        let tasking = try SweepSupport.model(opening: repo)
        tasking.open(file: "Sources/Ainkrad/Features/Sidebar/SidebarRow.swift", pinned: true)
        try SweepSupport.waitUntilLoaded(tasking)
        SweepSupport.spin(until: 10) { tasking.tasks.tasks.count >= 6 }
        tasking.terminals.add()
        tasking.showTasks()

        // E7 screen 15: an agent rewrote an open file — its changes washed and barred, the review bar, a chip.
        let view = "Sources/Ainkrad/Features/Sidebar/SidebarFilter.swift"
        let original = """
            import SwiftUI

            /// Narrows the sidebar's threads to those matching what is typed.
            struct SidebarFilter: View {
                @Binding var query: String
                @Environment(\\.ainkradSkin) private var skin

                var body: some View {
                    HStack(spacing: skin.size.s6) {
                        Image(systemName: "line.3.horizontal.decrease")
                        TextField("Filter", text: $query)
                            .textFieldStyle(.plain)
                    }
                    .padding(.horizontal, skin.size.s8)
                    .accessibilityLabel("Filter threads")
                }
            }

            """
        try original.write(to: repo.appendingPathComponent(view), atomically: true, encoding: .utf8)
        let agenting = try SweepSupport.model(opening: repo)
        agenting.open(file: view, pinned: true)
        try SweepSupport.waitUntilLoaded(agenting)
        var rewritten = original.components(separatedBy: "\n")
        rewritten[11] = "                .textFieldStyle(.roundedBorder)"
        rewritten.insert("                .onSubmit { query = query.trimmingCharacters(in: .whitespaces) }", at: 12)
        rewritten.remove(at: 15)
        try rewritten.joined(separator: "\n").write(to: repo.appendingPathComponent(view), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: repo.appendingPathComponent(view).path)
        Task { await agenting.diskChanged() }
        SweepSupport.spin(until: 10) { agenting.agent.files[view] != nil }
        agenting.agent.showingWas = true

        // E7 screen 16: Review All — a file Forge had read, changed while closed, and a new one.
        let sort = "Sources/Ainkrad/Features/Sidebar/SidebarSort.swift"
        let sortText = "import Foundation\n\n/// Orders threads: waiting on you first, then by last update.\nenum SidebarSort {\n    static func order(_ a: Int, _ b: Int) -> Bool {\n        a < b\n    }\n}\n"
        try sortText.write(to: repo.appendingPathComponent(sort), atomically: true, encoding: .utf8)
        let reviewing = try SweepSupport.model(opening: repo)
        reviewing.open(file: sort, pinned: true)
        try SweepSupport.waitUntilLoaded(reviewing)
        reviewing.close(sort)
        try sortText.replacingOccurrences(of: "        a < b\n", with: "        // Newest first.\n        a > b\n")
            .write(to: repo.appendingPathComponent(sort), atomically: true, encoding: .utf8)
        try "# Changelog\n\n- Sidebar: threads sort newest first.\n".write(to: repo.appendingPathComponent("CHANGELOG.md"), atomically: true, encoding: .utf8)
        await_(reviewing) {
            await $0.diskChanged(paths: [sort, "CHANGELOG.md"].map { repo.appendingPathComponent($0).path })
            await $0.agent.diffsReady()
        }
        reviewing.agent.reviewingAll = true

        // E7 screen 17: ⌘I on a selection — the Ask Agent card.
        let asking = try SweepSupport.model(opening: repo)
        asking.open(file: "Sources/Ainkrad/Features/Sidebar/SidebarRow.swift", pinned: true)
        try SweepSupport.waitUntilLoaded(asking)
        if let document = asking.activeDocument {
            let text = document.storage.string as NSString
            document.selection = text.range(of: "HStack(spacing: skin.size.s8) {")
            document.caretRect = CGRect(x: 80, y: 10 * 25.9 + 4, width: 1, height: 25)
        }
        asking.beginAsk()
        asking.agent.ask?.prompt = "Make the selection capsule animate in with the motion budget"

        // Screen 5: welcome, with recents (the sample repo has a worktree).
        let docs = MemoryDocs()
        let welcomeStore = ForgeStore(documents: docs)
        welcomeStore.noteOpened("/Users/me/Projects/OptimusBackend", at: Date(timeIntervalSinceNow: -86_400))
        welcomeStore.noteOpened(repo.path(percentEncoded: false), at: Date(timeIntervalSinceNow: -120))
        welcomeStore.update { $0.lastWorkspace = nil }
        let welcome = ForgeModel(store: welcomeStore)

        for (theme, skin) in [("neon", AinkradSkin.standard), ("glass", glass)] {
            let hostTheme = HostTheme(HostThemeTokens(skin: skin))
            hostTheme.updateStatusColors(
                HostStatusColors(
                    success: skin.color(skin.palette.success), warning: skin.color(skin.palette.warning),
                    danger: skin.color(skin.palette.danger)))
            hostTheme.updateTerminalPalette(HostTerminalPalette(skin.terminal))
            let screens: [(String, ForgeModel)] = [
                ("e21-window", window), ("e21-changes", changes), ("e21-unsaved", closing), ("e22-welcome", welcome),
                ("e24-quick-open", quick), ("e24-command-palette", commands),
                ("e23-split", split), ("e23-split-stacked", stacked),
                ("e25-rename", renaming), ("e25-new-file", creating),
                ("e31-conflict", conflicted),
                ("e32-settings-applied", tuned),
                ("e41-search", searching),
                ("e42-replace", replacing),
                ("e51-issues", diagnosed),
                ("e52-hover", hovering),
                ("e52-references", referencing),
                ("e53-signature", typing),
                ("e54-rename", renamingSymbol),
                ("e54-rename-preview", previewing),
                ("e61-terminal", terminal),
                ("e62-git", gitting),
                ("e63-tasks", tasking),
                ("e71-agent-inline", agenting),
                ("e72-review-all", reviewing),
                ("e73-ask-agent", asking),
            ]
            for (name, model) in screens {
                // The sweep window never becomes key, so an inline name field loses focus right after it shows
                // and ends its edit; start each edit afresh for every capture.
                if name == "e25-rename" { model.beginRename("Sources/Ainkrad/Features/Sidebar/SidebarGlassCapsule.swift") }
                if name == "e25-new-file" { model.beginNew(folder: false, in: "Sources/Ainkrad/Features/Sidebar") }
                try LiveCapture.shoot(
                    RootView(model: model, theme: hostTheme)
                        .frame(width: 1200, height: 760)
                        .background(skin.color(skin.palette.background))
                        .ainkradSkin(skin)
                        // As the host: Exo 2 under Neon, the system face under Glass.
                        .environment(
                            \.ainkradTypography, AinkradTypography(fontFamilyName: theme == "neon" ? "Exo 2" : nil)
                        )
                        .environment(\.colorScheme, .dark),
                    size: CGSize(width: 1200, height: 760),
                    to: URL(fileURLWithPath: out).appendingPathComponent("\(name)-\(theme).png"))
            }
        }
    }
}
