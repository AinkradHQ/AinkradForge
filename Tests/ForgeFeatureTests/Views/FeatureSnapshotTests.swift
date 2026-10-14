import AppKit
import ForgeLanguage
import SwiftUI
import XCTest

@testable import ForgeFeature

/// The mockup features built after design parity (mockups 05, 07, 08, 14), off-screen under Neon like
/// `SnapshotTests`, whose `Snapshot` helper they use. Clocks are frozen; what reads a random path is masked.
@MainActor
final class FeatureSnapshotTests: XCTestCase {
    private var repo: URL!

    override func setUp() async throws {
        repo = try SampleRepo.make()
    }

    override func tearDown() async throws {
        if let repo { try? FileManager.default.removeItem(at: repo.deletingLastPathComponent()) }
    }

    /// Mockup 05: Open Folder…, Clone Repository…, New File.
    func testWelcome() throws {
        let model = ForgeModel(store: ForgeStore(documents: MemoryDocs()))
        // Noon UTC: the recent's date ("1 Jan 1") is the same day in any time zone from −11 to +11 (FD57).
        model.store.update { $0.recents = [.init(path: repo.path, opened: .distantPast.addingTimeInterval(12 * 3_600))] }
        var settings = EditorSettings()
        settings.serverPaths = Dictionary(uniqueKeysWithValues: LanguageRegistry.servers.map { ($0.id, "/nonexistent/forge-snapshot") })
        model.editorSettings = settings
        // The recent's folder is random per run.
        try Snapshot.assertMatches(model, named: "welcome", masking: [CGRect(x: 300, y: 446, width: 600, height: 20)])
    }

    /// Clone Repository…: git's progress, and git's message when it fails.
    func testCloneDialog() throws {
        let clone = GitClone(parent: URL(fileURLWithPath: "/Users/forge/Projects"))
        clone.url = "https://github.com/AinkradHQ/AinkradForge.git"
        clone.phase = .cloning(step: "Receiving objects", fraction: 0.42)
        let size = CGSize(width: 520, height: 300)
        try Snapshot.assertMatches(
            CloneDialog(clone: clone, opened: { _ in }, close: {}).frame(width: CloneDialog.width), named: "clone-progress", size: size)
        clone.phase = .failed("repository 'https://github.com/AinkradHQ/AinkradForge.git/' not found")
        try Snapshot.assertMatches(
            CloneDialog(clone: clone, opened: { _ in }, close: {}).frame(width: CloneDialog.width), named: "clone-failed", size: size)
    }

    /// Mockup 14: a running task's `running · 0:18`, on a frozen clock.
    func testRunningTaskTimer() throws {
        try "build: ; xcodebuild\ntest: ; sleep 600\ngenerate: ; xcodegen\n"
            .write(to: repo.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
        let model = try Snapshot.model(opening: repo)
        SweepSupport.spin(until: 10) { model.tasks.tasks.count >= 3 }
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        model.tasks.now = { start }
        let test = try XCTUnwrap(model.tasks.tasks.first { $0.name == "test" })
        model.runTask(test)
        model.tasks.now = { start + 18 }
        model.showTasks()
        XCTAssertEqual(model.tasks.elapsed(test.id), "0:18")
        try Snapshot.assertMatches(model, named: "tasks-running")
        model.tasks.stop(test, in: model.terminals)
    }

    /// FP57 / FP63: a selected result line carries its action — ✕ in Search, ⇄ in Replace.
    func testResultRowActions() throws {
        let match = LineMatch(line: 19, text: "            if isSelected { Capsule().glassEffect(.regular) }", ranges: [NSRange(location: 15, length: 10)])
        let rows = VStack(spacing: 0) {
            ResultLineRow(
                match: match, isSelected: true, replacement: nil, action: RowAction(glyph: "✕", help: "Dismiss") {},
                onClick: {}, onDoubleClick: {})
            ResultLineRow(
                match: match, isSelected: true, replacement: { _, _ in "isActive" },
                action: RowAction(glyph: "⇄", help: "Replace this one") {}, onClick: {}, onDoubleClick: {})
        }
        .frame(width: 280)
        try Snapshot.assertMatches(rows, named: "result-actions", size: CGSize(width: 300, height: 80))
    }
}
