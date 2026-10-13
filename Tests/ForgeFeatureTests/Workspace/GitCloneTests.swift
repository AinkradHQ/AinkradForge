import XCTest

@testable import ForgeFeature

/// Clone Repository… against a local bare repository (no network): the clone, git's failure, a folder that is
/// already there, and Cancel. XCTest: the clone reports back through main-actor hops the test waits for.
@MainActor
final class GitCloneTests: XCTestCase {
    private var base: URL!

    override func setUp() async throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("forge-clone-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: base.appending(path: "into"), withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let base { try? FileManager.default.removeItem(at: base) }
    }

    private func git(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=Forge", "-c", "user.email=forge@example.com"] + arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
    }

    /// `<base>/Shop.git`, a bare repository with one commit holding README.md.
    private func bareRepository() throws -> URL {
        let work = base.appending(path: "work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], in: work)
        try "# Shop\n".write(to: work.appending(path: "README.md"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: work)
        try git(["commit", "-qm", "first"], in: work)
        try git(["clone", "-q", "--bare", work.path, base.appending(path: "Shop.git").path], in: base)
        return base.appending(path: "Shop.git")
    }

    private func wait(_ seconds: TimeInterval = 20, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    func testNamesURLsAndProgress() {
        XCTAssertEqual(GitClone.repositoryName("https://github.com/AinkradHQ/AinkradForge.git"), "AinkradForge")
        XCTAssertEqual(GitClone.repositoryName("git@github.com:owner/repo"), "repo")
        XCTAssertEqual(GitClone.repositoryName("git@host:repo.git/"), "repo")
        XCTAssertEqual(GitClone.repositoryName("/tmp/x/Shop.git"), "Shop")
        XCTAssertNil(GitClone.repositoryName("  "))
        XCTAssertTrue(GitClone.looksLikeRepository(" https://github.com/owner/repo.git\n"))
        XCTAssertTrue(GitClone.looksLikeRepository("git@github.com:owner/repo.git"))
        XCTAssertFalse(GitClone.looksLikeRepository("remember to buy milk"))
        XCTAssertFalse(GitClone.looksLikeRepository("someone@example.com"))
        let progress = GitClone.progress("Cloning into 'x'...\nremote: Counting objects: 100% (3/3)\rReceiving objects:  42% (123/290)")
        XCTAssertEqual(progress?.step, "Receiving objects")
        XCTAssertEqual(progress?.fraction, 0.42)
    }

    func testClonesALocalRepositoryAndHandsBackItsFolder() throws {
        let source = try bareRepository()
        let clone = GitClone(parent: base.appending(path: "into"))
        clone.url = " \(source.path) "
        XCTAssertEqual(clone.destination?.lastPathComponent, "Shop")
        var opened: URL?
        clone.start { opened = $0 }
        XCTAssertTrue(clone.isCloning)
        wait { opened != nil || !clone.isCloning }
        XCTAssertEqual(opened?.standardizedFileURL.path, base.appending(path: "into/Shop").standardizedFileURL.path)
        XCTAssertEqual(try String(contentsOf: base.appending(path: "into/Shop/README.md"), encoding: .utf8), "# Shop\n")
        XCTAssertEqual(clone.phase, .editing)
    }

    func testGitsFailureIsShownAndNothingIsLeftBehind() {
        let clone = GitClone(parent: base.appending(path: "into"))
        clone.url = base.appending(path: "Missing.git").path
        clone.start { _ in XCTFail("nothing to clone") }
        wait { !clone.isCloning }
        guard case .failed(let message) = clone.phase else { return XCTFail("\(clone.phase)") }
        XCTAssertTrue(message.contains("does not exist"), message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appending(path: "into/Missing").path))
    }

    func testAFolderThatIsThereIsNeverTouched() throws {
        let existing = base.appending(path: "into/Shop")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try "mine".write(to: existing.appending(path: "keep.txt"), atomically: true, encoding: .utf8)
        let clone = GitClone(parent: base.appending(path: "into"))
        clone.url = try bareRepository().path
        clone.start { _ in XCTFail("must not clone over a folder") }
        guard case .failed(let message) = clone.phase else { return XCTFail("\(clone.phase)") }
        XCTAssertTrue(message.hasPrefix("Shop already exists in "), message)
        XCTAssertEqual(try String(contentsOf: existing.appending(path: "keep.txt"), encoding: .utf8), "mine")
    }

    /// A transport that never answers (a stand-in ssh that sleeps): Cancel stops git and clears its folder.
    func testCancelStopsTheCloneAndClearsItsFolder() throws {
        let clone = GitClone(parent: base.appending(path: "into"))
        clone.environment = ["GIT_SSH_COMMAND": "sleep 3 #"]
        clone.url = "ssh://forge.invalid/owner/Slow.git"
        clone.start { _ in XCTFail("cancelled") }
        wait(2) { FileManager.default.fileExists(atPath: self.base.appending(path: "into/Slow").path) }
        XCTAssertTrue(clone.isCloning)
        clone.cancel()
        wait { !clone.isCloning }
        XCTAssertEqual(clone.phase, .editing, "a cancel is not an error")
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appending(path: "into/Slow").path))
    }
}
