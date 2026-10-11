import AppKit
import XCTest

@testable import ForgeFeature

/// Real processes in a sized window. XCTest, not Swift Testing: the terminal's main-queue work has to run
/// while the test waits.
@MainActor
final class TerminalDrawerTests: XCTestCase {
    private let window = NSWindow(
        contentRect: NSRect(x: -3000, y: -3000, width: 600, height: 300), styleMask: .borderless, backing: .buffered,
        defer: false)

    /// Puts the terminal in a window at a real size, which starts its process.
    private func show(_ drawer: TerminalDrawer, _ id: Int) {
        guard let view = drawer.view(id) else { return XCTFail("no view") }
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        window.contentView?.addSubview(view)
    }

    private func wait(_ seconds: TimeInterval = 10, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    func testExitStatusDecodes() {
        XCTAssertEqual(TerminalDrawer.exitStatus(768), 3)
        XCTAssertEqual(TerminalDrawer.exitStatus(0), 0)
        XCTAssertEqual(TerminalDrawer.exitStatus(15), 143)  // SIGTERM
    }

    func testATaskKeepsItsTabAndExitCode() throws {
        let drawer = TerminalDrawer()
        drawer.begin(root: URL(fileURLWithPath: NSTemporaryDirectory()))
        let id = try XCTUnwrap(drawer.add(command: "exit 3", title: "fail"))
        XCTAssertTrue(drawer.isOpen)
        XCTAssertTrue(drawer.isBusy(id))
        show(drawer, id)
        wait { drawer.tabs.first?.ended == true }
        XCTAssertEqual(drawer.tabs.map(\.title), ["fail"])
        XCTAssertEqual(drawer.tabs.first?.exitCode, 3)
        XCTAssertFalse(drawer.isBusy(id))
    }

    func testAShellThatExitsClosesItsTabAndTheLastOneHidesTheDrawer() throws {
        let drawer = TerminalDrawer()
        drawer.begin(root: URL(fileURLWithPath: NSTemporaryDirectory()))
        let id = try XCTUnwrap(drawer.add())
        XCTAssertFalse(drawer.isBusy(id))
        show(drawer, id)
        wait(2) { false }  // the login shell starting
        drawer.view(id)?.send(txt: "exit\n")
        wait { drawer.tabs.isEmpty }
        XCTAssertTrue(drawer.tabs.isEmpty)
        XCTAssertFalse(drawer.isOpen)
    }

    /// A task runs in its own tab and keeps how it went once it ends.
    func testATaskRunKeepsItsResult() throws {
        let drawer = TerminalDrawer()
        let runner = TaskRunner()
        runner.follow(drawer, model: ForgeModel(store: ForgeStore(documents: MemoryDocs())))
        drawer.begin(root: URL(fileURLWithPath: NSTemporaryDirectory()))
        let task = WorkspaceTask(group: "Makefile", name: "fail", shows: "make fail", command: "exit 2")
        runner.run(task, in: drawer)
        let tab = try XCTUnwrap(runner.running[task.id])
        XCTAssertEqual(drawer.tabs.map(\.title), ["make fail"])
        show(drawer, tab)
        wait { runner.results[task.id] != nil }
        XCTAssertEqual(runner.results[task.id]?.exitCode, 2)
        XCTAssertEqual(runner.results[task.id]?.succeeded, false)
        XCTAssertNil(runner.running[task.id])
        XCTAssertEqual(runner.last, task)
    }
}
