import ForgeLanguage
import Foundation
import Testing

@testable import ForgeFeature

@MainActor
@Suite("Agent review")
struct AgentReviewTests {
    private let before = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n"

    /// Line 5 changed, a line added after 10, line 15 removed.
    private var after: String {
        var lines = before.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines[4] = "line 5 by the agent"
        lines.insert("added by the agent", at: 10)
        lines.remove(at: 15)
        return lines.joined(separator: "\n")
    }

    @Test func linesChipsAndHunksFollowTheChanges() throws {
        let review = AgentReview()
        review.reloaded("a.swift", before: before, after: after)
        let lines = review.lines("a.swift")
        #expect(lines.written == [5, 11])
        #expect(lines.removedAfter == [15])
        #expect(review.anchorLine("a.swift", hunk: 0) == 5)
        #expect(review.hunk("a.swift", containing: 11) == 1)
        #expect(review.hunk("a.swift", containing: 15) == 2)
        #expect(review.hunk("a.swift", containing: 3) == nil)
    }

    /// Mockup 15: the chip sits after its line's text; a line too long for it flips the chip above the line, at
    /// the editor's right edge (below, on the first line), so it never covers the changed text.
    @Test func theChipSitsAfterTheLineOrFlipsClearOfIt() {
        let chip = CGSize(width: 200, height: 22)
        let short = CGRect(x: 60, y: 100, width: 300, height: 20)
        #expect(ChangeChip.origin(anchor: short, chip: chip, width: 1000, gap: 28, margin: 16) == CGPoint(x: 388, y: 98))
        let long = CGRect(x: 60, y: 100, width: 800, height: 20)
        #expect(ChangeChip.origin(anchor: long, chip: chip, width: 1000, gap: 28, margin: 16) == CGPoint(x: 784, y: 76))
        let top = CGRect(x: 60, y: 4, width: 800, height: 20)
        #expect(ChangeChip.origin(anchor: top, chip: chip, width: 1000, gap: 28, margin: 16) == CGPoint(x: 784, y: 26))
    }

    @Test func undoingEachChangeRestoresItsOldLines() throws {
        for index in 0..<3 {
            let review = AgentReview()
            review.reloaded("a.swift", before: before, after: after)
            let change = try #require(review.undo("a.swift", hunk: index))
            let undone = TextChange.apply([change], to: after)
            review.edited("a.swift", text: undone)
            // That change is gone; the other two remain.
            #expect(review.files["a.swift"]?.diff.hunks.count == 2)
            #expect(TextChange.apply([try #require(review.undoAll("a.swift", text: undone))], to: undone) == before)
        }
    }

    @Test func keepingFoldsAChangeIntoTheBaselineAndTypingKeepsAll() {
        let review = AgentReview()
        review.reloaded("a.swift", before: before, after: after)
        review.keep("a.swift", hunk: 1, text: after)
        #expect(review.lines("a.swift").written == [5])
        // A second outside edit compares against the same baseline (with the kept change).
        review.reloaded("a.swift", before: after, after: after + "tail\n")
        #expect(review.files["a.swift"]?.diff.hunks.count == 3)
        review.edited("a.swift", text: after + "tail\nmine\n")
        #expect(review.files["a.swift"] == nil)
    }
}
