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

enum SweepSupport {
    @MainActor static func model(opening repo: URL) throws -> ForgeModel {
        let model = ForgeModel(store: ForgeStore(documents: MemoryDocs()))
        model.request(.open(repo))
        spin(until: 10) { !(model.workspace?.tree.isEmpty ?? true) }
        return model
    }

    @MainActor static func waitUntilLoaded(_ model: ForgeModel) throws {
        spin(until: 5) { model.activeDocument?.state == .ready }
    }

    /// Runs the main run loop (and with it the main queue) until `done` or the deadline.
    @MainActor static func spin(until seconds: TimeInterval, _ done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    /// The host registers its bundled faces (Exo 2, JetBrains Mono) at launch; the test runner doesn't,
    /// so borrow the installed app's for true-to-app shots.
    static func registerHostFonts() {
        let resources = URL(fileURLWithPath: "/Applications/Ainkrad.app/Contents/Resources")
        let fonts = (try? FileManager.default.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)) ?? []
        for font in fonts where font.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(font as CFURL, .process, nil)
        }
    }

    /// `glass-dark.theme` on the standard skin, coloured by `glass-dark.scheme`, composed the way the host's
    /// `ThemeCatalog.compose` does.
    static func glassSkin(themes: URL) throws -> AinkradSkin {
        let dir = themes.appendingPathComponent("glass")
        let base = try JSONEncoder().encode(AinkradSkin.standard)
        let theme = try Data(contentsOf: dir.appendingPathComponent("glass-dark.theme"))
        let variant = try XCTUnwrap(ainkradLoadThemes([base, theme]).themes["glass.dark"])
        var scheme = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("glass-dark.scheme")))
                as? [String: Any])
        scheme.removeValue(forKey: "appearance")
        scheme.removeValue(forKey: "host")
        scheme["base"] = "glass.dark"
        return try AinkradThemeFile(
            decoding: JSONSerialization.data(withJSONObject: scheme), bases: ["glass.dark": variant]
        ).skin
    }
}

/// A throwaway repo shaped like the mockups: a committed tree, one modified file, one new one, a worktree.
enum SampleRepo {
    static func make() throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("forge-sweep-\(UUID().uuidString.prefix(8))")
        let repo = base.appendingPathComponent("Ainkrad")
        let files: [String: String] = [
            "Sources/Ainkrad/Features/Sidebar/SidebarRow.swift": sidebarRow,
            "Sources/Ainkrad/Features/Sidebar/SidebarView.swift": "import SwiftUI\n\nstruct SidebarView: View {\n    var body: some View { Text(\"Sidebar\") }\n}\n",
            "Sources/Ainkrad/Features/Sidebar/SidebarModel.swift": "import Observation\n\n@Observable final class SidebarModel {}\n",
            "Sources/Ainkrad/Features/Home/HomeView.swift": "import SwiftUI\n",
            "Sources/Ainkrad/Features/Settings/SettingsView.swift": "import SwiftUI\n",
            "Sources/Ainkrad/Core/Log.swift": "import os\n",
            "Sources/Ainkrad/AinkradApp.swift": "import SwiftUI\n\n@main struct AinkradApp: App {\n    var body: some Scene { WindowGroup { Text(\"Ainkrad\") } }\n}\n",
            "Tests/AinkradTests/SidebarTests.swift": "import Testing\n",
            "scripts/release.sh": "#!/bin/bash\nset -euo pipefail\n",
            "project.yml": "name: Ainkrad\noptions:\n  bundleIdPrefix: com.ainkrad\n",
            "AGENTS.md": "# Agents\n",
            "Makefile": "build: ; xcodebuild\n",
        ]
        for (path, text) in files {
            let url = repo.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try git(repo, "init", "-q", "-b", "feat/glass-sidebar")
        try git(repo, "add", "-A")
        try git(repo, "-c", "user.name=Forge", "-c", "user.email=forge@example.com", "commit", "-q", "-m", "init")
        try git(repo, "worktree", "add", "-q", "-b", "development", base.appendingPathComponent("Ainkrad-dev").path)
        // A modified file and a new one, as the mockup shows.
        try (sidebarRow.replacingOccurrences(of: ".contentShape(Rectangle())", with: ".contentShape(Rectangle())\n        .help(thread.branchName)"))
            .write(to: repo.appendingPathComponent("Sources/Ainkrad/Features/Sidebar/SidebarRow.swift"), atomically: true, encoding: .utf8)
        try "import SwiftUI\n\nstruct SidebarGlassCapsule: View {\n    var body: some View { Capsule() }\n}\n"
            .write(to: repo.appendingPathComponent("Sources/Ainkrad/Features/Sidebar/SidebarGlassCapsule.swift"), atomically: true, encoding: .utf8)
        return repo
    }

    private static func git(_ repo: URL, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = repo
        try process.run()
        process.waitUntilExit()
    }

    static let sidebarRow = """
        import SwiftUI
        import AinkradAppKit

        /// One thread row in the sidebar: status dot, title, time, agent badge.
        struct SidebarRow: View {
            @Environment(\\.ainkradSkin) private var skin
            let thread: ThreadSummary
            let isSelected: Bool

            var body: some View {
                HStack(spacing: skin.size.s8) {
                    StatusDot(state: thread.state)
                    Text(thread.title).lineLimit(1)
                    Spacer()
                    Text(thread.updated, format: .relative(presentation: .numeric))
                }
                .padding(.horizontal, skin.size.s8)
                .background {
                    if isSelected { Capsule().glassEffect(.regular) }
                }
                .contentShape(Rectangle())
            }
        }

        // MARK: - Previews

        #Preview("Selected · Glass") { SidebarRow(thread: .sample, isSelected: true) }

        """
}

/// Captures a desktop-level window by id (`screencapture -l`): never the user's screen, never focus.
@MainActor
enum LiveCapture {
    private final class KeyAppearancePanel: NSPanel {
        override var isKeyWindow: Bool { true }
        override var isMainWindow: Bool { true }
        override var canBecomeKey: Bool { false }
        @objc var hasKeyAppearance: Bool { true }
        @objc var hasMainAppearance: Bool { true }
        @objc var _hasActiveAppearance: Bool { true }
        @objc var _hasActiveAppearanceIgnoringKeyFocus: Bool { true }
    }

    static func shoot(_ view: some View, size: CGSize, to url: URL) throws {
        let panel = KeyAppearancePanel(
            contentRect: NSRect(origin: CGPoint(x: 200, y: 200), size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.hasShadow = false
        panel.contentView = NSHostingView(
            rootView: view.environment(\.ainkradMotionBudget, .frozen).environment(\.controlActiveState, .key))
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(3))  // tree-sitter highlights asynchronously
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(panel.windowNumber), url.path]
        try capture.run()
        capture.waitUntilExit()
        XCTAssertEqual(capture.terminationStatus, 0, "no capture for \(url.lastPathComponent)")
    }
}
