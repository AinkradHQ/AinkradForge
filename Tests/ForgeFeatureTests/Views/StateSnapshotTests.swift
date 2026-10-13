import AppKit
import ForgeLanguage
import XCTest

@testable import ForgeFeature

/// E6's states (mockup 19), off-screen under Neon like `SnapshotTests`: no git and no server (B), a server
/// starting with indexing progress (C), a server that crashed twice (D). Screen A is `SnapshotTests.testEmptyFolder`.
/// The servers are shell scripts standing in for one, so nothing depends on what is installed.
@MainActor
final class StateSnapshotTests: XCTestCase {
    private var base: URL!

    override func setUp() async throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("forge-states-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let base { try? FileManager.default.removeItem(at: base) }
    }

    /// B: a folder that is not a repository, a Ruby file (no server for Ruby): the Changes tab offers Initialize
    /// Repository, the hint bar sits under the breadcrumb, the status bar says "no git" and "○ No language server".
    func testNoGitNoServer() throws {
        let folder = base.appendingPathComponent("deploy-scripts")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "require \"open3\"\n\ndef release(version)\n  tag = \"v#{version}\"\n  Open3.capture3(\"git\", \"tag\", tag)\nend\n"
            .write(to: folder.appendingPathComponent("release.rb"), atomically: true, encoding: .utf8)
        let model = ForgeModel(store: ForgeStore(documents: MemoryDocs()))
        model.request(.open(folder))
        SweepSupport.spin(until: 10) { model.workspace?.isLoading == false && !(model.workspace?.files.isEmpty ?? true) }
        model.sideTab = .changes
        model.open(file: "release.rb", pinned: true)
        try SweepSupport.waitUntilLoaded(model)
        XCTAssertEqual(model.serverBar(for: "release.rb")?.language, "Ruby")
        // CESE's parked find panel over line 1 (see `SnapshotTests.testSearch`), below the hint bar here.
        try Snapshot.assertMatches(model, named: "no-git-no-server", masking: [CGRect(x: 314, y: 114, width: 886, height: 28)])
    }

    /// C: the server is up but has not answered `initialize`, and reports indexing: spinner, progress, "–" counts.
    /// (Not `exec cat > /dev/null`: that closes the script's stdout, which reads as a dead server.)
    func testServerStarting() throws {
        let progress = #"{"jsonrpc":"2.0","method":"$/progress","params":{"token":"index","value":{"kind":"begin","title":"Indexing","message":"412 / 1280"}}}"#
        let model = try model(server: "printf 'Content-Length: \(progress.utf8.count)\\r\\n\\r\\n%s' '\(progress)'\ncat > /dev/null")
        SweepSupport.spin(until: 10) { model.languages.progress["sourcekit-lsp"] != nil }
        XCTAssertEqual(model.languages.statuses["sourcekit-lsp"], .starting)
        XCTAssertEqual(model.languages.progress["sourcekit-lsp"], "Indexing 412 / 1280")
        try Snapshot.assertMatches(model, named: "server-starting", masking: [CGRect(x: 314, y: 70, width: 886, height: 28)])
    }

    /// D: the server died twice in a row: the red bar with Show Log and Restart Server, a red dot and Restart.
    func testServerCrashed() throws {
        let model = try model(server: "kill -SEGV $$")
        SweepSupport.spin(until: 10) { model.languages.statuses["sourcekit-lsp"] == .crashed("signal 11 (SEGV)") }
        XCTAssertEqual(model.serverBar(for: SnapshotTests.sidebarRow)?.kind, .stopped)
        try Snapshot.assertMatches(model, named: "server-crashed", masking: [CGRect(x: 314, y: 114, width: 886, height: 28)])
    }

    /// The sample repo with SidebarRow.swift open, its Swift server the script `body`.
    private func model(server body: String) throws -> ForgeModel {
        let repo = try SampleRepo.make()
        addTeardownBlock { try? FileManager.default.removeItem(at: repo.deletingLastPathComponent()) }
        let script = base.appendingPathComponent("server.sh")
        try "#!/bin/sh\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let model = try Snapshot.model(opening: repo)
        model.setServerPath("sourcekit-lsp", script.path)
        model.open(file: SnapshotTests.sidebarRow, pinned: true)
        try SweepSupport.waitUntilLoaded(model)
        return model
    }
}
