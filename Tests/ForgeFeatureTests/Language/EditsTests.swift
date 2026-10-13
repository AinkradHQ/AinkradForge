import ForgeLanguage
import Foundation
import SwiftUI
import Testing

@testable import ForgeFeature

/// How a server's changes land: through the editor showing the file, an open buffer, or the file on disk.
@MainActor
@Suite("Server edits")
struct EditsTests {
    private func workspace(_ files: [String: String]) async throws -> (ForgeModel, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("forge-edits-\(UUID().uuidString.prefix(8))")
        for (path, text) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let model = ForgeModel(store: ForgeStore(documents: MemoryDocs()))
        await model.start(launch: root.path)
        return (model, root)
    }

    private func change(_ line: Int, _ from: Int, _ to: Int, _ text: String) -> TextChange {
        TextChange(start: (line, from), end: (line, to), newText: text)
    }

    @Test func theShownFileChangesThroughItsEditorAndAClosedOneOnDisk() async throws {
        let (model, root) = try await workspace(["Shown.swift": "let count = 1\n", "Closed.swift": "print(count)\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        model.open(file: "Shown.swift", pinned: true)
        for _ in 0..<50 where model.documents["Shown.swift"]?.state != .ready { try await Task.sleep(for: .milliseconds(20)) }

        #expect(model.apply(["Shown.swift": [change(0, 4, 9, "total")], "Closed.swift": [change(0, 6, 11, "total")]]))
        // The shown file waits for its editor (undoable there); the closed one is written.
        let edits = try #require(model.editorEdits["Shown.swift"])
        #expect(edits.ranges == [NSRange(location: 4, length: 5)] && edits.texts == ["total"])
        #expect(try String(contentsOf: root.appending(path: "Closed.swift"), encoding: .utf8) == "print(total)\n")
    }

    @Test func thePreviewLeavesUntickedHunksAsTheyWere() async throws {
        let lines = (0..<20).map { $0 == 2 || $0 == 17 ? "let count = \($0)" : "line \($0)" }
        let (model, root) = try await workspace(["A.swift": lines.joined(separator: "\n") + "\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let changes = ["A.swift": [change(2, 4, 9, "total"), change(17, 4, 9, "total")]]
        model.pendingEdit = PendingEdit(
            title: "Rename", changes: changes,
            plans: [ReplacePlan.make(path: "A.swift", original: try #require(model.text(of: "A.swift")),
                updated: TextChange.apply(changes["A.swift"]!, to: try #require(model.text(of: "A.swift"))), count: 2)])
        let hunks = try #require(model.pendingEdit?.plans.first?.diff?.hunks)
        #expect(hunks.count == 2)
        model.pendingEdit?.rejected["A.swift"] = [hunks[1].id]

        model.applyPendingEdit()
        let written = try String(contentsOf: root.appending(path: "A.swift"), encoding: .utf8)
        #expect(written.contains("let total = 2") && written.contains("let count = 17"))
        #expect(model.pendingEdit == nil)
    }

    @Test func returnPreviewsARenameAndShiftReturnRenamesNow() {
        // The kit field's onReturn hands over the held modifiers (kit batch 6): ↵ previews, ⇧↵ renames now.
        #expect(RenameField.previews(on: []))
        #expect(!RenameField.previews(on: .shift))
        #expect(!RenameField.previews(on: [.shift, .command]))
    }
}
