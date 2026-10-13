import XCTest

@testable import ForgeFeature

/// Mockup 14's `running · 0:18`: how long a running task has run, on a frozen clock.
@MainActor
final class TaskTimerTests: XCTestCase {
    func testElapsedTicksWhileRunningAndStopsWithTheTask() throws {
        var clock = Date(timeIntervalSinceReferenceDate: 1_000)
        let runner = TaskRunner()
        runner.now = { clock }
        let drawer = TerminalDrawer()
        drawer.begin(root: URL(fileURLWithPath: NSTemporaryDirectory()))
        let task = WorkspaceTask(group: "Makefile", name: "test", shows: "make test", command: "sleep 30")
        XCTAssertNil(runner.elapsed(task.id), "not running yet")
        runner.run(task, in: drawer)
        XCTAssertEqual(runner.elapsed(task.id), "0:00")
        clock += 18
        XCTAssertEqual(runner.elapsed(task.id), "0:18")
        clock += 12 * 60 - 18 + 5
        XCTAssertEqual(runner.elapsed(task.id), "12:05")
        clock = Date(timeIntervalSinceReferenceDate: 1_000 + 3_723)
        XCTAssertEqual(runner.elapsed(task.id), "1:02:03")
        let tab = try XCTUnwrap(runner.running[task.id])
        runner.ended(tab: tab, exitCode: 0)
        XCTAssertNil(runner.elapsed(task.id), "a finished task shows its result, not a timer")
        XCTAssertEqual(runner.results[task.id]?.seconds, 3_723)
    }
}
