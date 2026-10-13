import AinkradAppKit
import AppKit
import ForgeLanguage
import SwiftUI
import XCTest

@testable import ForgeFeature

/// Forge's main screens under Neon, drawn OFF-SCREEN (`NSHostingView` in a borderless window that is never
/// ordered in, then `cacheDisplay`) and compared against the goldens in `Goldens/` — a check, unlike `SweepTests`.
/// Neon only: off-screen drawing cannot show Liquid Glass. Each scene reuses the sweep's `SampleRepo`.
///
/// What keeps a shot stable: 1× pixels, the system faces (no `Exo 2` borrowed from an installed app), the frozen
/// motion budget, a window that is never key (no caret blink), no language server (the override points at a
/// path that does not exist, so a diagnostic can never land mid-shot), a mask over text that reads the clock, and
/// a shot taken only once four draws a quarter second apart agree. Small antialiasing drift sits under the
/// tolerance; a new macOS or font build can move more than that — re-record then, and look at the diffs.
/// Off-screen, CodeEdit's (hidden) find bar draws over line 1; that is a capture artefact, the same every run.
///
/// Re-record after an intended change: `TEST_RUNNER_FORGE_GOLDEN_RECORD=1 make test` (xcodebuild hands the
/// test runner `TEST_RUNNER_`-prefixed variables without the prefix), then look at every changed PNG.
///
/// XCTest, not Swift Testing: the scenes wait on main-queue work (loads, highlighting, SwiftUI updates).
@MainActor
final class SnapshotTests: XCTestCase {
    static let sidebarRow = "Sources/Ainkrad/Features/Sidebar/SidebarRow.swift"

    private var repo: URL!

    override func setUp() async throws {
        repo = try SampleRepo.make()
    }

    override func tearDown() async throws {
        if let repo { try? FileManager.default.removeItem(at: repo.deletingLastPathComponent()) }
    }

    /// The window: the tree expanded down to the open file, three tabs.
    func testWindow() throws {
        let model = try Snapshot.model(opening: repo)
        Snapshot.expandSidebar(model)
        model.open(file: "Sources/Ainkrad/Features/Sidebar/SidebarView.swift", pinned: true)
        model.open(file: "project.yml", pinned: true)
        model.open(file: Self.sidebarRow, pinned: true)
        try SweepSupport.waitUntilLoaded(model)
        XCTAssertEqual(model.tabs.paths.count, 3)
        try Snapshot.assertMatches(model, named: "window")
    }

    /// More tabs than fit: the active (last opened) one is scrolled into view (E1D1 FD29).
    func testLongTabStripShowsTheActiveTab() throws {
        let model = try Snapshot.model(opening: repo)
        for path in (model.workspace?.files ?? []).sorted() where path != Self.sidebarRow {
            model.open(file: path, pinned: true)
        }
        model.open(file: Self.sidebarRow, pinned: true)
        try SweepSupport.waitUntilLoaded(model)
        XCTAssertGreaterThan(model.tabs.paths.count, 9)
        try Snapshot.assertMatches(model, named: "long-tabs")
    }

    /// An empty folder: the tree and the editor say so, and the tree offers New File (E1D1 FD32).
    func testEmptyFolder() throws {
        let empty = repo.deletingLastPathComponent().appendingPathComponent("Empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let model = ForgeModel(store: ForgeStore(documents: MemoryDocs()))
        model.request(.open(empty))
        SweepSupport.spin(until: 10) { model.workspace?.isLoading == false }
        XCTAssertEqual(model.workspace?.files, [])
        try Snapshot.assertMatches(model, named: "empty-folder")
    }

    /// A narrow window (760 pt): the sidebar gives way and the status bar degrades, nothing clips (E1D1 FD28).
    func testNarrowWindow() throws {
        let model = try Snapshot.model(opening: repo)
        Snapshot.expandSidebar(model)
        model.open(file: Self.sidebarRow, pinned: true)
        try SweepSupport.waitUntilLoaded(model)
        // CESE's parked find panel, as in `testSearch`.
        try Snapshot.assertMatches(
            model, named: "narrow", size: CGSize(width: 760, height: 560),
            masking: [CGRect(x: 280, y: 70, width: 480, height: 28)])
    }

    /// Split editor at 900 pt: each breadcrumb stays on one line (E1D1 FD27); the right pane's tabs overflow.
    func testSplitNarrow() throws {
        let model = try Snapshot.model(opening: repo)
        model.open(file: Self.sidebarRow, pinned: true)
        model.splitEditor(stacked: false)
        for path in ["AGENTS.md", "Makefile", "project.yml"] { model.open(file: path, pinned: true) }
        try SweepSupport.waitUntilLoaded(model)
        try Snapshot.assertMatches(
            model, named: "split-narrow", size: CGSize(width: 900, height: 560),
            masking: [CGRect(x: 300, y: 70, width: 600, height: 28)])
    }

    /// Welcome at 520 pt (three apps tiled): the recents card narrows with the window (E1D1 FD35).
    func testWelcomeNarrow() throws {
        let model = ForgeModel(store: ForgeStore(documents: MemoryDocs()))
        model.store.update { $0.recents = [.init(path: repo.path, opened: .distantPast)] }
        // The repo's folder name is random per run: mask the path line.
        try Snapshot.assertMatches(
            model, named: "welcome-narrow", size: CGSize(width: 520, height: 560),
            masking: [CGRect(x: 30, y: 360, width: 370, height: 20)])
    }

    /// ⌘P over the window, filtered to "sbrow".
    func testQuickOpen() throws {
        let model = try Snapshot.model(opening: repo)
        Snapshot.expandSidebar(model)
        model.open(file: Self.sidebarRow, pinned: true)
        try SweepSupport.waitUntilLoaded(model)
        model.palette = "sbrow"
        try Snapshot.assertMatches(model, named: "quick-open")
    }

    /// The Search tab with its results, one opened at its line.
    func testSearch() throws {
        let model = try Snapshot.model(opening: repo)
        model.showSearch()
        model.search.query.text = "isSelected"
        model.search.include = "Sources/**, Tests/**"
        model.search.schedule(root: repo, files: model.workspace?.files ?? [], buffers: [:], delay: .zero)
        SweepSupport.spin(until: 5) { if case .done = model.search.status { true } else { false } }
        XCTAssertFalse(model.search.results.isEmpty, "the search found nothing")
        model.open(file: Self.sidebarRow, pinned: false)
        model.pendingLine = 19
        try SweepSupport.waitUntilLoaded(model)
        // The summary ends in the search's own duration ("· 3 ms"): the clock, not the UI. Off-screen drawing also
        // shows CESE's parked find panel half-drawn over line 1, its placeholder text varying run to run.
        // ponytail: masked; un-mask if the panel ever shows there live.
        try Snapshot.assertMatches(
            model, named: "search",
            masking: [CGRect(x: 100, y: 260, width: 100, height: 22), CGRect(x: 314, y: 70, width: 886, height: 28)])
    }

    /// Review All: a file Forge had read, changed while closed, and a new one.
    func testReviewAll() throws {
        let sort = "Sources/Ainkrad/Features/Sidebar/SidebarSort.swift"
        let sortText =
            "import Foundation\n\n/// Orders threads: waiting on you first, then by last update.\nenum SidebarSort {\n    static func order(_ a: Int, _ b: Int) -> Bool {\n        a < b\n    }\n}\n"
        try sortText.write(to: repo.appendingPathComponent(sort), atomically: true, encoding: .utf8)
        let model = try Snapshot.model(opening: repo)
        model.open(file: sort, pinned: true)
        try SweepSupport.waitUntilLoaded(model)
        model.close(sort)
        try sortText.replacingOccurrences(of: "        a < b\n", with: "        // Newest first.\n        a > b\n")
            .write(to: repo.appendingPathComponent(sort), atomically: true, encoding: .utf8)
        try "# Changelog\n\n- Sidebar: threads sort newest first.\n"
            .write(to: repo.appendingPathComponent("CHANGELOG.md"), atomically: true, encoding: .utf8)
        let paths = [sort, "CHANGELOG.md"].map { repo.appendingPathComponent($0).path }
        await_(model) { await $0.diskChanged(paths: paths) }
        XCTAssertEqual(
            model.reviewEntries.map(\.path), ["CHANGELOG.md", sort], "Review All should list both changed files")
        model.agent.reviewingAll = true
        try Snapshot.assertMatches(model, named: "review-all")
    }
}

/// Off-screen drawing and golden comparison for `SnapshotTests`.
@MainActor
enum Snapshot {
    static let size = CGSize(width: 1200, height: 760)
    /// A channel may drift this far (of 255) before its pixel counts as changed: antialiasing, not content.
    static let channelTolerance = 24
    /// This share of changed pixels (~90 at 1200×760) fails the shot. Renaming one sidebar tab ("Search" →
    /// "Find") changes 0.05–0.1%; a missing row, panel or wrong theme far more. Run-to-run drift measured: 0.
    static let pixelTolerance = 0.0001
    static let goldens = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Goldens")
    static var isRecording: Bool { ProcessInfo.processInfo.environment["FORGE_GOLDEN_RECORD"] == "1" }

    /// `SweepSupport.model(opening:)`, with every language server pointed at nothing first.
    static func model(opening repo: URL) throws -> ForgeModel {
        let model = ForgeModel(store: ForgeStore(documents: MemoryDocs()))
        var settings = EditorSettings()
        settings.serverPaths = Dictionary(
            uniqueKeysWithValues: LanguageRegistry.servers.map { ($0.id, "/nonexistent/forge-snapshot") })
        model.editorSettings = settings
        model.request(.open(repo))
        SweepSupport.spin(until: 10) { !(model.workspace?.tree.isEmpty ?? true) && model.workspace?.isLoading == false }
        return model
    }

    static func expandSidebar(_ model: ForgeModel) {
        for folder in ["Sources", "Sources/Ainkrad", "Sources/Ainkrad/Features", "Sources/Ainkrad/Features/Sidebar"] {
            model.toggle(folder: folder)
        }
    }

    /// Draws `model`'s window and compares it with `Goldens/<name>.png` (or records it).
    /// `masking` blanks rects (top-left origin, points) in both images first — for text that reads the clock.
    static func assertMatches(
        _ model: ForgeModel, named name: String, size: CGSize = size, masking masks: [CGRect] = [],
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        try assertMatches(RootView(model: model, theme: hostTheme()), named: name, size: size, masking: masks, file: file, line: line)
    }

    /// `assertMatches` for any view, drawn alone on the window's background.
    static func assertMatches(
        _ view: some View, named name: String, size: CGSize = size, masking masks: [CGRect] = [],
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let image = try XCTUnwrap(render(view, size: size), "the window did not draw", file: file, line: line)
        let golden = goldens.appendingPathComponent("\(name).png")
        if isRecording {
            try FileManager.default.createDirectory(at: goldens, withIntermediateDirectories: true)
            try png(image).write(to: golden)
            return
        }
        guard let data = try? Data(contentsOf: golden), let expected = NSBitmapImageRep(data: data)?.cgImage else {
            return XCTFail(
                "no golden at \(golden.path) — record with TEST_RUNNER_FORGE_GOLDEN_RECORD=1", file: file, line: line)
        }
        let changed = difference(image, expected, masking: masks)
        print("SNAPSHOT \(name) changed=\(String(format: "%.4f", changed * 100))%")
        if changed > pixelTolerance {
            let actual = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
                "forge-snapshot-\(name).png")
            try? png(image).write(to: actual)
            XCTFail(
                "\(name): \(String(format: "%.3f", changed * 100))% of pixels changed (allowed \(pixelTolerance * 100)%) — actual at \(actual.path)",
                file: file, line: line)
        }
    }

    /// The window, once four draws a quarter second apart agree: some layers land late (the fold ribbon after
    /// its ranges are computed, highlights after a parse), and two quick draws can both precede them.
    static func render(_ view: some View, size: CGSize = size) -> CGImage? {
        let skin = AinkradSkin.standard
        let host = NSHostingView(
            rootView: view
                .frame(width: size.width, height: size.height)
                .background(skin.color(skin.palette.background))
                .ainkradSkin(skin)
                .environment(\.ainkradTypography, AinkradTypography(fontFamilyName: nil))
                .environment(\.ainkradMotionBudget, .frozen)
                .environment(\.colorScheme, .dark))
        host.frame = NSRect(origin: .zero, size: size)
        // Never ordered in: nothing reaches the screen, nothing takes focus.
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        var previous: CGImage?
        var unchanged = 0
        let deadline = Date().addingTimeInterval(15)
        SweepSupport.spin(until: 0.5) { false }
        while Date() < deadline {
            host.layoutSubtreeIfNeeded()
            guard let shot = draw(host, size: size) else { return nil }
            unchanged = previous.map { difference(shot, $0) == 0 } == true ? unchanged + 1 : 0
            if unchanged == 3 { return shot }
            previous = shot
            SweepSupport.spin(until: 0.25) { false }
        }
        return previous
    }

    /// The Neon host theme `RootView` takes.
    static func hostTheme() -> HostTheme {
        let skin = AinkradSkin.standard
        let theme = HostTheme(HostThemeTokens(skin: skin))
        theme.updateStatusColors(
            HostStatusColors(
                success: skin.color(skin.palette.success), warning: skin.color(skin.palette.warning),
                danger: skin.color(skin.palette.danger)))
        theme.updateTerminalPalette(HostTerminalPalette(skin.terminal))
        return theme
    }

    private static func draw(_ view: NSView, size: CGSize) -> CGImage? {
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: Int(size.width) * 4, bitsPerPixel: 32)
        else { return nil }
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }

    /// The share of pixels where any channel moved more than `channelTolerance`, outside `masks`.
    static func difference(_ a: CGImage, _ b: CGImage, masking masks: [CGRect] = []) -> Double {
        guard a.width == b.width, a.height == b.height else { return 1 }
        let lhs = pixels(a)
        let rhs = pixels(b)
        // Shots are drawn at 1×: a point is a pixel.
        let masked = masks
        var changed = 0
        for index in stride(from: 0, to: lhs.count, by: 4) {
            let pixel = index / 4
            // Bitmap rows run top-down, as the masks do.
            let point = CGPoint(x: Double(pixel % a.width) + 0.5, y: Double(pixel / a.width) + 0.5)
            if masked.contains(where: { $0.contains(point) }) { continue }
            for channel in 0..<4 where abs(Int(lhs[index + channel]) - Int(rhs[index + channel])) > channelTolerance {
                changed += 1
                break
            }
        }
        return Double(changed) / Double(a.width * a.height)
    }

    /// RGBA8 in one colour space, so a decoded PNG and a fresh draw compare byte for byte.
    private static func pixels(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    private static func png(_ image: CGImage) throws -> Data {
        try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }
}
