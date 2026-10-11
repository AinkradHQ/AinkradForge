import AinkradAppKit
import AppKit
import SwiftUI
import XCTest

@testable import ForgeFeature

/// Runs `work` and spins the main run loop until it is done (XCTest's main-actor tests cannot await it).
@MainActor func await_(_ model: ForgeModel, _ work: @escaping (ForgeModel) async -> Void) {
    var done = false
    Task { await work(model); done = true }
    SweepSupport.spin(until: 15) { done }
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
