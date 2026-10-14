import AinkradAppKit
import Foundation
import Testing

@testable import ForgeFeature

/// E5: Grimoire's turn notices, the review grouped by turn, and Keep / Undo per turn.
@MainActor
@Suite("Turn review")
struct TurnReviewTests {
    private let lines = (1...12).map { "line \($0)" }.joined(separator: "\n") + "\n"

    private func turn(_ number: Int, files: [String], started: Date, prompt: String? = "do it", root: String = "/r") -> AgentTurn {
        AgentTurn(
            kind: AgentTurn.kind, root: root, thread: "t1", turn: number, agent: "Claude", prompt: prompt, files: files,
            startedAt: started.timeIntervalSince1970, endedAt: started.timeIntervalSince1970 + 5)
    }

    private func json(_ turn: AgentTurn) throws -> String { String(decoding: try JSONEncoder().encode(turn), as: UTF8.self) }

    // MARK: - Payloads

    @Test func turnNoticesAndLaunchesDecode() throws {
        let notice = turn(3, files: ["/r/a.swift"], started: Date(timeIntervalSince1970: 100))
        #expect(AgentTurn.decode(try json(notice)) == notice)
        #expect(AgentTurn.decode(#"{"kind":"askAgent","path":"/r","prompt":"x"}"#) == nil)
        #expect(AgentTurn.decode("not json") == nil)

        #expect(ForgeLaunch.decode(#"{"kind":"openDocument","path":"/r/a.swift","line":59}"#) == ForgeLaunch(path: "/r/a.swift", line: 59))
        #expect(ForgeLaunch.decode(#"{"kind":"openDocument","path":"/r","review":true}"#) == ForgeLaunch(path: "/r", review: true))
        #expect(ForgeLaunch.decode(#"{"kind":"openDocument","path":"/r/a","line":0}"#)?.line == 1)
        // An intent from another sender (Hoard), and a bare path, still open what they name.
        #expect(ForgeLaunch.decode(AinkradLaunchIntent(path: "/r/b.swift").json) == ForgeLaunch(path: "/r/b.swift"))
        #expect(ForgeLaunch.decode("/r/c") == ForgeLaunch(path: "/r/c"))
        #expect(ForgeLaunch.decode(nil) == nil)
    }

    // MARK: - Merging

    @Test func carryingAChangeOntoMovedOnTextRefusesWhenTheLinesOverlap() {
        let base = "a\nb\nc\nd\ne\n"
        let turn2 = "a\nB\nc\nd\ne\n"  // turn 2 changed line 2
        let now = "a\nB\nc\nd\nE\nf\n"  // then turn 3 changed line 5 and added one
        // Undo turn 2 on today's text: its line goes back, turn 3's stay.
        #expect(LineMerge.carry(now, from: turn2, to: base) == "a\nb\nc\nd\nE\nf\n")
        // Turn 3 edited line 2 too: no silent merge.
        #expect(LineMerge.carry("a\nBB\nc\nd\ne\n", from: turn2, to: base) == nil)
        // Inserting at the same place is a conflict too; next to it is not.
        #expect(LineMerge.carry("a\nx\nb\nc\nd\ne\n", from: base, to: "a\ny\nb\nc\nd\ne\n") == nil)
        #expect(LineMerge.carry("a\nb\nc\nx\nd\ne\n", from: base, to: "a\ny\nb\nc\nd\ne\n") == "a\ny\nb\nc\nx\nd\ne\n")
        // CRLF lines are lines ("\r\n" is one Swift Character, but splits here).
        #expect(LineMerge.carry("a\r\nB\r\nc\r\nD\r\n", from: "a\r\nB\r\nc\r\nd\r\n", to: "a\r\nb\r\nc\r\nd\r\n") == "a\r\nb\r\nc\r\nD\r\n")
        #expect(LineMerge.counts("a\nb\n", "a\nB\nc\n") == (added: 2, removed: 1))
        #expect(LineMerge.counts(nil, "x\ny") == (added: 2, removed: 0))
    }

    // MARK: - Grouping

    @Test func writesGroupByTheTurnRunningThenAndTheRestByTimeWindow() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        var ledger = TurnLedger()
        ledger.observe("a.swift", before: "1", after: "2", at: t0.addingTimeInterval(1))  // turn 2
        ledger.observe("b.swift", before: "x", after: "y", at: t0.addingTimeInterval(2))  // turn 2
        ledger.add(turn(2, files: ["a.swift", "b.swift"], started: t0), at: t0.addingTimeInterval(5))
        ledger.observe("c.swift", before: "p", after: "q", at: t0.addingTimeInterval(60))  // a formatter
        ledger.observe("d.swift", before: "p", after: "q", at: t0.addingTimeInterval(90))  // same window
        ledger.observe("a.swift", before: "2", after: "3", at: t0.addingTimeInterval(400))  // turn 3
        ledger.add(turn(3, files: ["a.swift"], started: t0.addingTimeInterval(399)), at: t0.addingTimeInterval(401))
        ledger.observe("e.swift", before: "p", after: "q", at: t0.addingTimeInterval(1_000))  // a later window
        // A write the watcher reports again (same text) is not a second step.
        ledger.observe("e.swift", before: "p", after: "q", at: t0.addingTimeInterval(1_001))

        let groups = ledger.groups(in: ["a.swift", "b.swift", "c.swift", "d.swift", "e.swift"])
        #expect(groups.map(\.title) == ["Outside edits · 1 file", "Claude · turn 3 · 1 file", "Outside edits · 2 files", "Claude · turn 2 · 2 files"])
        let turn2 = groups[3]
        #expect(turn2.files.map(\.path) == ["a.swift", "b.swift"])
        #expect(turn2.files[0].before == "1" && turn2.files[0].after == "2")
        #expect(groups[1].files.first?.before == "2")
        #expect(groups[2].files.map(\.path) == ["c.swift", "d.swift"])

        // Files no longer in review drop out; a group with none left goes.
        #expect(ledger.groups(in: ["a.swift"]).map(\.title) == ["Claude · turn 3 · 1 file", "Claude · turn 2 · 1 file"])

        // A kept group stays as one "Kept" row; its steps fold into the baseline once nothing older is pending.
        ledger.keep(turn2)
        #expect(ledger.groups(in: ["a.swift", "b.swift"]).map { "\($0.title) \($0.kept)" } == ["Claude · turn 3 · 1 file false", "Claude · turn 2 · 2 files true"])
        #expect(ledger.foldKept("a.swift")?.after == "2")
        #expect(ledger.steps(of: "a.swift").map(\.after) == ["3"])
    }

    // MARK: - Keep / undo through the model

    private func workspace() async throws -> (ForgeModel, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("forge-turns-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try lines.write(to: root.appending(path: "A.txt"), atomically: true, encoding: .utf8)
        let model = ForgeModel(store: ForgeStore(documents: MemoryDocs()))
        await model.start(launch: root.path)
        // Seen once (opened and closed), so a later write while closed is reviewed against it.
        model.open(file: "A.txt", pinned: true)
        for _ in 0..<50 where model.documents["A.txt"]?.state != .ready { try await Task.sleep(for: .milliseconds(20)) }
        model.close("A.txt")
        return (model, root)
    }

    /// The agent writes `text` to A.txt during turn `number`, which Grimoire then announces.
    private func agentTurn(_ number: Int, _ model: ForgeModel, _ root: URL, _ text: String) async throws {
        let started = Date().addingTimeInterval(-0.5)
        try text.write(to: root.appending(path: "A.txt"), atomically: true, encoding: .utf8)
        await model.diskChanged(paths: [root.appending(path: "A.txt").path])
        NotificationCenter.default.post(
            name: AgentTurn.notification,
            object: try json(turn(number, files: [root.appending(path: "A.txt").path], started: started, root: root.path)))
    }

    private func disk(_ root: URL) throws -> String { try String(contentsOf: root.appending(path: "A.txt"), encoding: .utf8) }

    @Test func undoingAnOlderTurnKeepsTheNewerOnesChangesWhenTheirLinesDiffer() async throws {
        let (model, root) = try await workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let two = lines.replacingOccurrences(of: "line 2\n", with: "line two\n")
        try await agentTurn(2, model, root, two)
        try await agentTurn(3, model, root, two.replacingOccurrences(of: "line 11\n", with: "line eleven\n"))
        #expect(model.reviewsByTurn)
        let groups = model.turnGroups
        #expect(groups.map(\.title) == ["Claude · turn 3 · 1 file", "Claude · turn 2 · 1 file"])

        #expect(model.undo(group: groups[1]))
        let undone = try disk(root)
        #expect(undone.contains("line 2\n") && undone.contains("line eleven\n"))
        // Turn 3 is still in review, against the original text.
        #expect(model.turnGroups.map(\.title) == ["Claude · turn 3 · 1 file"])
        await model.agent.diffsReady()
        #expect(model.reviewEntries.first?.diff?.hunks.count == 1)

        // Keeping turn 3 folds it into the baseline: nothing is left to review.
        model.keep(group: try #require(model.turnGroups.first))
        #expect(model.agent.count == 0)
    }

    @Test func undoingAnOlderTurnWhoseLinesANewerTurnEditedAsksFirst() async throws {
        let (model, root) = try await workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let two = lines.replacingOccurrences(of: "line 2\n", with: "line two\n")
        try await agentTurn(2, model, root, two)
        try await agentTurn(3, model, root, two.replacingOccurrences(of: "line two\n", with: "line TWO\n"))
        let older = try #require(model.turnGroups.last)

        #expect(!model.undo(group: older))
        #expect(try disk(root).contains("line TWO"))
        #expect(model.newerConflicts(older) == ["Claude · turn 3 · 1 file"])

        // Asked and accepted: the file goes back to before turn 2, turn 3's change to it with it.
        #expect(model.undo(group: older, force: true))
        #expect(try disk(root) == lines)
        #expect(model.agent.count == 0)
    }

    @Test func doneUndoesTheUntickedChangesOfATurnAndKeepsTheRest() async throws {
        let (model, root) = try await workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let changed = lines.replacingOccurrences(of: "line 2\n", with: "line two\n").replacingOccurrences(of: "line 11\n", with: "line eleven\n")
        try await agentTurn(1, model, root, changed)
        let group = try #require(model.turnGroups.first)
        let file = try #require(group.files.first)
        #expect(ForgeModel.diff(file).hunks.count == 2)
        model.agent.turns.unticked[group.id + "|" + file.path] = [1]

        model.finishTurnReview()
        let written = try disk(root)
        #expect(written.contains("line two") && written.contains("line 11\n"))
        #expect(model.agent.count == 0 && !model.reviewsByTurn)
    }

    @Test func aTurnForAnotherWorkspaceOrFilesOutsideItIsIgnored() async throws {
        let (model, root) = try await workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        model.receive(turn: try json(turn(1, files: ["/elsewhere/x.swift"], started: Date())))
        model.receive(turn: #"{"kind":"askAgent"}"#)
        #expect(!model.reviewsByTurn)
    }

    @Test func aLaunchIntoAnOpenWorkspaceKeepsItAndGoesToTheLine() async throws {
        let (model, root) = try await workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try await agentTurn(1, model, root, lines.replacingOccurrences(of: "line 2\n", with: "line two\n"))
        let file = root.appending(path: "A.txt").path
        await model.start(launch: #"{"kind":"openDocument","path":"\#(file)","line":7}"#)
        // The review survived (no reopen), the file is open at line 7.
        #expect(model.reviewsByTurn)
        #expect(model.tabs.active == "A.txt" && model.pendingLine == 7)
        await model.start(launch: #"{"kind":"openDocument","path":"\#(root.path)","review":true}"#)
        #expect(model.agent.reviewingAll)
    }
}
