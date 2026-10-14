import Foundation
import SwiftUI
import Testing

@testable import ForgeFeature

/// ✕ on a result (FP57, mockup 07) and ⇄ on one match (FP63, mockup 08).
@MainActor
@Suite("Result actions")
struct ResultActionTests {
    private func workspace(_ files: [String: Data]) async throws -> (ForgeModel, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("forge-acts-\(UUID().uuidString.prefix(8))")
        for (path, data) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let model = ForgeModel(store: ForgeStore(documents: MemoryDocs()))
        await model.start(launch: root.path)
        return (model, root)
    }

    private func search(_ model: ForgeModel, _ query: String) async throws {
        model.search.query.text = query
        model.search.replacement = "isActive"
        model.rerunSearch()
        try await settle(model)
    }

    private func settle(_ model: ForgeModel) async throws {
        try await Task.sleep(for: .milliseconds(20))
        for _ in 0..<100 {
            if case .done = model.search.status { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func onlyTheChosenLinesAreReplaced() throws {
        let text = "a isSelected\nb\r\nc isSelected isSelected\nd isSelected"
        let regex = try #require(try SearchQuery(text: "isSelected").compile())
        let out = TextSearch.replace(in: text, regex: regex, with: "X", isRegex: false, preserveCase: false) { $0 == 3 }
        #expect(out.count == 2)
        #expect(out.text == "a isSelected\nb\r\nc X X\nd isSelected")
    }

    @Test func replacingOneMatchLeavesTheRestOfItsLine() async throws {
        let (model, root) = try await workspace(["A.swift": Data("isSelected = isSelected\n".utf8)])
        defer { try? FileManager.default.removeItem(at: root) }
        try await search(model, "isSelected")
        #expect(model.replace(in: "A.swift", line: 1) == 1)
        try await settle(model)
        #expect(try String(contentsOf: root.appending(path: "A.swift"), encoding: .utf8) == "isActive = isSelected\n")
        // The row is still listed for the match left on it.
        #expect(model.search.lineCount == 1)
    }

    @Test func dismissingDropsALineOrAFileFromTheListAndFromReplaceAll() async throws {
        let (model, root) = try await workspace([
            "A.swift": Data("let isSelected = 1\nisSelected()\n".utf8), "B.swift": Data("var isSelected = 2\n".utf8),
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        try await search(model, "isSelected")
        #expect(model.search.lineCount == 3)

        model.search.dismiss("A.swift", line: 2)
        #expect(model.search.results.first { $0.path == "A.swift" }?.matches.map(\.line) == [1])
        if case .done(let lines, let files, _, _) = model.search.status { #expect(lines == 2 && files == 2) }
        model.search.dismiss("B.swift")
        #expect(model.search.results.map(\.path) == ["A.swift"])

        model.replaceAll()
        try await settle(model)
        #expect(try String(contentsOf: root.appending(path: "A.swift"), encoding: .utf8) == "let isActive = 1\nisSelected()\n")
        #expect(try String(contentsOf: root.appending(path: "B.swift"), encoding: .utf8) == "var isSelected = 2\n")
        // The re-run keeps the dismissed results out; a new query brings them back.
        #expect(model.search.results.isEmpty)
        try await search(model, "isSel")
        #expect(model.search.lineCount == 2)
    }

    @Test func replacingOneMatchWritesAClosedFileInItsEncodingAndAnOpenOneInItsBuffer() async throws {
        let closed = Data([0xEF, 0xBB, 0xBF]) + Data("let isSelected = 1\r\nisSelected()\r\n".utf8)
        let (model, root) = try await workspace(["Closed.swift": closed, "Open.swift": Data("isSelected\nvar isSelected = 2\n".utf8)])
        defer { try? FileManager.default.removeItem(at: root) }
        model.open(file: "Open.swift", pinned: true)
        for _ in 0..<50 where model.documents["Open.swift"]?.state != .ready { try await Task.sleep(for: .milliseconds(20)) }
        try await search(model, "isSelected")
        #expect(model.search.lineCount == 4)

        #expect(model.replace(in: "Closed.swift", line: 2) == 1)
        try await settle(model)
        #expect(try Data(contentsOf: root.appending(path: "Closed.swift")) == Data([0xEF, 0xBB, 0xBF]) + Data("let isSelected = 1\r\nisActive()\r\n".utf8))
        #expect(model.search.lineCount == 3)

        #expect(model.replace(in: "Open.swift", line: 2) == 1)
        try await settle(model)
        let open = try #require(model.documents["Open.swift"])
        #expect(open.storage.string == "isSelected\nvar isActive = 2\n" && open.isDirty)
        #expect(try String(contentsOf: root.appending(path: "Open.swift"), encoding: .utf8) == "isSelected\nvar isSelected = 2\n")
        #expect(model.search.lineCount == 2)
    }

    @Test func replacingOneOnALineThatNoLongerMatchesSaysSo() async throws {
        // FD45: ⇄ on a row whose line changed since the search is a notice, not a silent no-op.
        let (model, root) = try await workspace(["A.swift": Data("isSelected()\n".utf8)])
        defer { try? FileManager.default.removeItem(at: root) }
        try await search(model, "isSelected")
        try Data("done()\n".utf8).write(to: root.appending(path: "A.swift"))
        model.notice = nil
        #expect(model.replace(in: "A.swift", line: 1) == 0)
        #expect(model.notice?.hasPrefix("Nothing to replace on line 1 of A.swift") == true)
    }

    @Test func aDismissedMatchStaysDismissedWhenItsLinesShift() async throws {
        // FD44: ✕ on line 2, then a line added above (the list is not re-run): Replace All and ⇄ follow the
        // matches, not the old line numbers — the dismissed one is never touched, the others all are.
        let (model, root) = try await workspace(["A.swift": Data("isSelected(1)\nisSelected(2)\nisSelected(1)\n".utf8)])
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "A.swift")
        try await search(model, "isSelected")
        model.search.dismiss("A.swift", line: 2)
        try Data("// new\nisSelected(1)\nisSelected(2)\nisSelected(1)\n".utf8).write(to: file)
        #expect(model.search.results.first?.matches.map(\.line) == [1, 3])

        // ⇄ on the listed line 3 (the second `isSelected(1)`, now on line 4).
        #expect(model.replace(in: "A.swift", line: 3) == 1)
        #expect(try String(contentsOf: file, encoding: .utf8) == "// new\nisSelected(1)\nisSelected(2)\nisActive(1)\n")
        try await settle(model)
        #expect(model.search.results.first?.matches.map(\.line) == [2])

        try Data("// new\n// newer\nisSelected(1)\nisSelected(2)\nisActive(1)\n".utf8).write(to: file)
        model.replaceAll()
        try await settle(model)
        #expect(try String(contentsOf: file, encoding: .utf8) == "// new\n// newer\nisActive(1)\nisSelected(2)\nisActive(1)\n")
        #expect(model.search.results.isEmpty)
    }

    @Test func aDismissedMatchStaysDismissedWhenAnIdenticalLineIsAddedAbove() async throws {
        // E1D4 FD54: dismissals were keyed by (text, occurrence among identical lines); an identical line added
        // above shifted the occurrence, so Replace All replaced the dismissed match and skipped another.
        let (model, root) = try await workspace(["A.swift": Data("isSelected(1)\nisSelected(2)\nisSelected(1)\n".utf8)])
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "A.swift")
        try await search(model, "isSelected")
        model.search.dismiss("A.swift", line: 3)
        try Data("isSelected(1)\nisSelected(1)\nisSelected(2)\nisSelected(1)\n".utf8).write(to: file)
        model.replaceAll()
        try await settle(model)
        #expect(try String(contentsOf: file, encoding: .utf8) == "isActive(1)\nisActive(1)\nisActive(2)\nisSelected(1)\n")
    }

    @Test func aDismissedMatchStaysDismissedWhenAnIdenticalLineIsRemovedAbove() async throws {
        let (model, root) = try await workspace(["A.swift": Data("isSelected(1)\nx\nisSelected(1)\n".utf8)])
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "A.swift")
        try await search(model, "isSelected")
        model.search.dismiss("A.swift", line: 3)
        try Data("x\nisSelected(1)\n".utf8).write(to: file)
        model.replaceAll()
        try await settle(model)
        #expect(try String(contentsOf: file, encoding: .utf8) == "x\nisSelected(1)\n")

        // A re-run keeps following it: one more identical line above, and the list still leaves it out.
        try Data("isSelected(1)\nx\nisSelected(1)\n".utf8).write(to: file)
        model.rerunSearch()
        try await settle(model)
        #expect(model.search.results.first?.matches.map(\.line) == [1])
    }

    @Test func aFocusedRowRunsItsActionFromTheKeyboard() {
        // FD46: the nested ✕ / ⇄ can't take Full Keyboard Access focus, so the focused row runs them: ⌫ and ⇧↵.
        let dismiss = RowAction(glyph: "✕", name: "Dismiss result", key: .delete) {}
        #expect(dismiss.runs(on: .delete, modifiers: []))
        #expect(!dismiss.runs(on: .delete, modifiers: .command) && !dismiss.runs(on: .return, modifiers: .shift))
        let replace = RowAction(glyph: "⇄", name: "Replace this match", key: .shiftReturn) {}
        #expect(replace.runs(on: .return, modifiers: .shift))
        #expect(!replace.runs(on: .return, modifiers: []) && !replace.runs(on: .delete, modifiers: []))
        #expect(!RowAction(glyph: "‹", name: "Previous change") {}.runs(on: .delete, modifiers: []))
        // E1D4 FD60: VoiceOver names are words; the key goes to the tooltip and the hint, never the name.
        #expect(dismiss.help == "Dismiss result (⌫)" && dismiss.hint == "Or press Delete on the row")
        #expect(RowAction(glyph: "✕", name: "Hide for this session") {}.help == "Hide for this session")
        for action in [dismiss, replace] { #expect(!action.name.contains(where: { "✕⇄⌫⇧↵".contains($0) })) }
    }
}
