import AinkradAppKit
import AppKit
import ForgeLanguage
import SwiftUI
import XCTest

@testable import ForgeFeature

/// Perf baselines: typing in a big file, opening it, and loading a big repo's tree. Each prints its numbers
/// (`PERF …` in the test log) and fails only past a bound several times what was measured, so a busy machine
/// does not flake it but a regression by an order of magnitude does. Off-screen: windows are never ordered in.
///
/// Measured on an M-series Mac, Debug, 2026-10-12, load average 60–200: typing main-thread p95 6.5–9 ms (bound
/// 16 ms; the E1 spike's 4–5 ms was a Release build), a 50k-line Swift file read in 11–150 ms (bound 3 s) and
/// first drawn in 0.6–1.4 s of main-thread work (bound 5 s), a 20k-file repo's tree in 0.5–2.1 s (bound 15 s).
///
/// XCTest, not Swift Testing: every step waits on main-queue work.
@MainActor
final class PerfBaselineTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
            "forge-perf-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    /// Insert + layout + draw per key, mid-file in a 50k-line Swift file — what the E1 spike timed.
    func testTypingP95() throws {
        let file = root.appendingPathComponent("Big.swift")
        try Self.swiftSource(lines: 50_000).write(to: file, atomically: true, encoding: .utf8)
        let document = EditorDocument(url: file)
        await_(ForgeModel(store: ForgeStore(documents: MemoryDocs()))) { _ in await document.load() }
        XCTAssertEqual(document.state, .ready)

        let window = Self.window(CodeEditor(document: document, palette: nil, goToLine: 25_000, onEdit: {}))
        let host = try XCTUnwrap(window.contentView)
        SweepSupport.spin(until: 2) { false }  // the jump, and the first highlight pass
        let textView = try XCTUnwrap(Self.scrollView(in: host)?.documentView)
        let input = try XCTUnwrap(textView as? NSTextInputClient, "the editor's text view takes no text input")
        // The jump moved the caret, but a window that is never ordered in does not scroll: bring the caret's line
        // into view by hand, or the bracket highlight reads a range from the caret back to the visible text.
        let caret = input.firstRect(forCharacterRange: input.selectedRange(), actualRange: nil)
        textView.scrollToVisible(textView.convert(window.convertFromScreen(caret), from: nil).insetBy(dx: 0, dy: -300))
        textView.layoutSubtreeIfNeeded()
        XCTAssertTrue(textView.visibleRect.minY > 0, "the caret's line was not scrolled into view")
        let canvas = try XCTUnwrap(textView.bitmapImageRepForCachingDisplay(in: textView.visibleRect))

        let before = document.storage.length
        /// One key: insert, lay out, draw — then let queued main-queue work (highlight results) run, as between
        /// keys. Timed twice: wall clock, and the main thread's own CPU time.
        func type(_ character: Character) -> (wall: Double, cpu: Double) {
            let start = ContinuousClock.now
            let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            input.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
            textView.layoutSubtreeIfNeeded()
            textView.cacheDisplay(in: textView.visibleRect, to: canvas)
            let cpu = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart) / 1e6
            let wall = Self.milliseconds(ContinuousClock.now - start)
            RunLoop.main.run(until: Date())
            return (wall, cpu)
        }
        let line = "let value = compute(index) "
        for character in line { _ = type(character) }  // warm-up: the first edits build the syntax tree's state
        let samples = String(repeating: line, count: 8).map(type)
        XCTAssertEqual(document.storage.length, before + line.count * 9, "the keys did not reach the buffer")
        let wall = Self.percentiles(samples.map(\.wall))
        let cpu = Self.percentiles(samples.map(\.cpu))
        print(
            "PERF typing keys=\(samples.count) wall p50=\(Self.format(wall.p50)) p95=\(Self.format(wall.p95)) max=\(Self.format(wall.max))ms · main-thread cpu p50=\(Self.format(cpu.p50)) p95=\(Self.format(cpu.p95)) max=\(Self.format(cpu.max))ms"
        )
        // The bound is on CPU time: wall clock on a loaded machine (load average 60 while this was written)
        // swings p95 from 12 to 85 ms run to run, while the work per key does not move.
        XCTAssertLessThan(
            cpu.p95, 16, "typing p95 \(Self.format(cpu.p95)) ms of main-thread work is past the 16 ms frame budget")
        XCTAssertLessThan(
            wall.p50, 16, "typing p50 \(Self.format(wall.p50)) ms (wall clock) is past the 16 ms frame budget")
    }

    /// From `open(file:)` to the editor's first layout and draw of a 50k-line Swift file.
    func testOpenFiftyThousandLineFile() throws {
        try Self.swiftSource(lines: 50_000).write(
            to: root.appendingPathComponent("Big.swift"), atomically: true, encoding: .utf8)
        let model = Self.model(opening: root)
        XCTAssertEqual(model.workspace?.files, ["Big.swift"])

        let start = ContinuousClock.now
        model.open(file: "Big.swift", pinned: true)
        let deadline = Date().addingTimeInterval(10)
        while model.activeDocument?.state != .ready, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
        }
        let loaded = Self.milliseconds(ContinuousClock.now - start)
        let document = try XCTUnwrap(model.activeDocument)
        XCTAssertEqual(document.state, .ready)
        let drawStart = ContinuousClock.now
        let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let window = Self.window(CodeEditor(document: document, palette: nil, onEdit: {}))
        let host = try XCTUnwrap(window.contentView)
        let canvas = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: canvas)
        let drawCPU = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart) / 1e6
        let drawWall = Self.milliseconds(ContinuousClock.now - drawStart)
        print(
            "PERF open-50k load=\(Self.format(loaded))ms firstDraw wall=\(Self.format(drawWall))ms cpu=\(Self.format(drawCPU))ms"
        )
        // Reading runs off the main thread (wall clock); the first layout and draw is main-thread work (CPU time,
        // which a loaded machine does not inflate).
        XCTAssertLessThan(loaded, 3_000, "reading a 50k-line file took \(Self.format(loaded)) ms")
        XCTAssertLessThan(
            drawCPU, 5_000, "the first draw of a 50k-line file took \(Self.format(drawCPU)) ms of main-thread work")
    }

    /// From opening a 20k-file git repo to its tree being built (listing, status, tasks scan, tree).
    func testTreeLoadOnTwentyThousandFiles() throws {
        for folder in 0..<200 {
            let dir = root.appendingPathComponent("Sources/Module\(folder)/Feature\(folder % 10)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for index in 0..<100 {
                try Data("let x\(index) = \(index)\n".utf8).write(to: dir.appendingPathComponent("File\(index).swift"))
            }
        }
        try Self.git(root, "init", "-q")
        try Self.git(root, "add", "-A")
        try Self.git(root, "-c", "user.name=Forge", "-c", "user.email=forge@example.com", "commit", "-q", "-m", "init")

        let start = ContinuousClock.now
        let model = Self.model(opening: root, timeout: 60)
        let elapsed = Self.milliseconds(ContinuousClock.now - start)
        XCTAssertEqual(model.workspace?.files.count, 20_000)
        XCTAssertEqual(model.workspace?.tree.first?.name, "Sources")
        print("PERF tree-20k files=\(model.workspace?.files.count ?? 0) load=\(Self.format(elapsed))ms")
        XCTAssertLessThan(elapsed, 15_000, "loading a 20k-file tree took \(Self.format(elapsed)) ms")
    }

    /// Review All over 20 closed 3,000-line files, every third line changed outside (E1D4 FD52: 27 s of main-thread
    /// diffing per render). Diffs are computed once, off the main thread; a render only reads them. Measured
    /// 2026-10-14, Debug: a render 150–270 ms (a fresh window included), the 20 diffs 6–7 s off the main thread.
    func testReviewAllDoesNotDiffOnTheMainThread() throws {
        let model = ForgeModel(store: ForgeStore(documents: MemoryDocs()))
        for file in 0..<20 {
            let old = (0..<3_000).map { "let value\($0) = \($0) // file \(file)" }
            let new = old.enumerated().map { $0.offset % 3 == 0 ? $0.element + " changed" : $0.element }
            model.agent.outside(
                "File\(file).swift", baseline: old.joined(separator: "\n") + "\n", current: new.joined(separator: "\n") + "\n")
        }
        model.agent.reviewingAll = true
        /// One render's main-thread cost: the entries, then the pane laid out and drawn.
        func render() -> Double {
            let start = ContinuousClock.now
            XCTAssertEqual(model.reviewEntries.count, 20)
            let window = Self.window(ReviewAllPane(model: model))
            if let host = window.contentView, let canvas = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: canvas)
            }
            return Self.milliseconds(ContinuousClock.now - start)
        }
        let pending = render()
        XCTAssertTrue(model.agent.otherDiffs.count < 20, "the diffs were computed on the main thread, in the render")
        let start = ContinuousClock.now
        await_(model) { await $0.agent.diffsReady() }
        let diffed = Self.milliseconds(ContinuousClock.now - start)
        XCTAssertEqual(model.reviewEntries.compactMap(\.diff).count, 20)
        let entriesStart = ContinuousClock.now
        for _ in 0..<10 { _ = model.reviewEntries }
        let entries = Self.milliseconds(ContinuousClock.now - entriesStart) / 10
        let cached = render()
        print(
            "PERF review-all files=20 render-while-diffing=\(Self.format(pending))ms diffs-off-main=\(Self.format(diffed))ms entries=\(Self.format(entries))ms render-cached=\(Self.format(cached))ms"
        )
        XCTAssertLessThan(entries, 20, "reading 20 cached entries took \(Self.format(entries)) ms")
        XCTAssertLessThan(pending, 1_000, "a render while diffing blocked the main thread \(Self.format(pending)) ms")
        XCTAssertLessThan(cached, 1_000, "a render of cached diffs blocked the main thread \(Self.format(cached)) ms")
    }

    /// Replace All over 20 closed 3,000-line files with 91 matches each (E1D5 FD62: 27 s on the main thread, every
    /// file diffed with the kit's quadratic diff although no hunk was unticked). Replace never diffs now; the
    /// preview diffs off the main thread.
    func testReplaceAllDoesNotDiffOnTheMainThread() throws {
        for file in 0..<20 {
            let lines = (0..<3_000).map { $0 % 33 == 0 ? "let isSelected\($0) = \($0) // file \(file)" : "let value\($0) = \($0)" }
            try (lines.joined(separator: "\n") + "\n").write(
                to: root.appendingPathComponent("File\(file).swift"), atomically: true, encoding: .utf8)
        }
        let model = Self.model(opening: root)
        model.search.query.text = "isSelected"
        model.search.replacement = "isActive"
        model.rerunSearch()
        SweepSupport.spin(until: 10) { if case .done = model.search.status { true } else { false } }
        XCTAssertEqual(model.search.lineCount, 1_820)

        let planStart = ContinuousClock.now
        let plan = model.replacePlan(for: "File0.swift")
        let planned = Self.milliseconds(ContinuousClock.now - planStart)
        XCTAssertNil(plan?.diff, "the preview's plan was diffed on the main thread")
        let start = ContinuousClock.now
        model.replaceAll()
        let replaced = Self.milliseconds(ContinuousClock.now - start)
        let written = try (0..<20).filter {
            try String(contentsOf: root.appendingPathComponent("File\($0).swift"), encoding: .utf8).contains("isActive2970 ")
        }
        print("PERF replace-all files=20 matches=1820 plan=\(Self.format(planned))ms replace-all-main=\(Self.format(replaced))ms")
        XCTAssertEqual(written.count, 20)
        XCTAssertLessThan(planned, 500, "one file's plan blocked the main thread \(Self.format(planned)) ms")
        XCTAssertLessThan(replaced, 3_000, "Replace All blocked the main thread \(Self.format(replaced)) ms")
    }

    /// A 20k-line file with one dismissed match, reformatted outside (every line re-indented), then Replace's plan
    /// (E1D5 FD69: 8.5 s on the main thread, Myers line diff of a rewrite).
    func testReplacePlanAfterAWholeFileRewrite() throws {
        let lines = (0..<20_000).map { $0 % 1_000 == 0 ? "let isSelected\($0) = \($0)" : "let value\($0) = \($0)" }
        let file = root.appendingPathComponent("Big.swift")
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let model = Self.model(opening: root)
        model.search.query.text = "isSelected"
        model.search.replacement = "isActive"
        model.rerunSearch()
        SweepSupport.spin(until: 10) { if case .done = model.search.status { true } else { false } }
        model.search.dismiss("Big.swift", line: 5_001)
        try (lines.map { "    " + $0 }.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)

        let start = ContinuousClock.now
        let plan = model.replacePlan(for: "Big.swift", keepingUnticked: true)
        let elapsed = Self.milliseconds(ContinuousClock.now - start)
        print("PERF replace-plan-rewrite lines=20000 plan=\(Self.format(elapsed))ms")
        XCTAssertNotNil(plan)
        XCTAssertLessThan(elapsed, 1_000, "the plan after a rewrite blocked the main thread \(Self.format(elapsed)) ms")
    }

    // MARK: - Support

    /// Opens `folder` with no language server (a server's start-up is not what these time).
    static func model(opening folder: URL, timeout: TimeInterval = 10) -> ForgeModel {
        let model = ForgeModel(store: ForgeStore(documents: MemoryDocs()))
        var settings = EditorSettings()
        settings.serverPaths = Dictionary(
            uniqueKeysWithValues: LanguageRegistry.servers.map { ($0.id, "/nonexistent/forge-perf") })
        model.editorSettings = settings
        model.request(.open(folder))
        SweepSupport.spin(until: timeout) {
            !(model.workspace?.tree.isEmpty ?? true) && model.workspace?.isLoading == false
        }
        return model
    }

    /// `view` in a borderless window that is never ordered in, laid out. Keep the window: the view dies with it.
    static func window(_ view: some View) -> NSWindow {
        let host = NSHostingView(
            rootView: view.frame(width: 1000, height: 700).ainkradSkin(.standard).environment(\.colorScheme, .dark))
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return window
    }

    static func scrollView(in view: NSView) -> NSScrollView? {
        (view as? NSScrollView) ?? view.subviews.lazy.compactMap(scrollView(in:)).first
    }

    /// Plausible Swift: types, functions, comments and strings, so highlighting has real work to do.
    static func swiftSource(lines: Int) -> String {
        var text = ""
        text.reserveCapacity(lines * 40)
        for index in 0..<(lines / 10) {
            text += """
                /// Item \(index): a documented value.
                struct Item\(index): Equatable {
                    let name = "item-\(index)"
                    var count: Int = \(index)
                    func doubled() -> Int {
                        // Twice the count.
                        count * 2
                    }
                }
                let item\(index) = Item\(index)()

                """
        }
        return text
    }

    static func git(_ repo: URL, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = repo
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " ")) failed")
    }

    static func percentiles(_ values: [Double]) -> (p50: Double, p95: Double, max: Double) {
        let sorted = values.sorted()
        return (sorted[sorted.count / 2], sorted[sorted.count * 95 / 100], sorted.last ?? 0)
    }

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    static func format(_ value: Double) -> String { String(format: "%.1f", value) }
}
