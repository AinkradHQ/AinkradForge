import AinkradAppKit
import Foundation
import Testing

@testable import ForgeFeature

@MainActor
@Suite("Replace")
struct ReplaceTests {
    @Test func untickedHunksKeepTheirOriginalLines() throws {
        let text = (1...20).map { $0 == 3 || $0 == 17 ? "let isSelected = \($0)" : "line \($0)" }.joined(separator: "\n")
        let regex = try #require(try SearchQuery(text: "isSelected").compile())
        let plan = ReplacePlan.make(path: "a.swift", text: text, regex: regex, replacement: "isActive", isRegex: false, preserveCase: false)
        #expect(plan.count == 2)
        let hunks = try #require(plan.diff?.hunks)
        #expect(hunks.count == 2)
        let partial = plan.text(rejecting: [hunks[1].id])
        #expect(partial.contains("let isActive = 3") && partial.contains("let isSelected = 17"))
        #expect(plan.text(rejecting: []) == plan.updated)
    }

    private func workspace(_ files: [String: Data]) async throws -> (ForgeModel, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("forge-replace-\(UUID().uuidString.prefix(8))")
        for (path, data) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let model = ForgeModel(store: ForgeStore(documents: MemoryDocs()))
        await model.start(launch: root.path)
        return (model, root)
    }

    private func settle(_ model: ForgeModel) async throws {
        for _ in 0..<100 {
            if case .done = model.search.status { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func replaceAllLeavesThePreviewsUntickedHunksAndANewQueryForgetsThem() async throws {
        let text = (1...20).map { $0 == 3 || $0 == 17 ? "let isSelected = \($0)" : "line \($0)" }.joined(separator: "\n") + "\n"
        let (model, root) = try await workspace(["A.swift": Data(text.utf8)])
        defer { try? FileManager.default.removeItem(at: root) }
        model.search.query.text = "isSelected"
        model.search.replacement = "isActive"
        model.rerunSearch()
        try await settle(model)
        let hunks = try #require(model.replacePlan(for: "A.swift")?.diff?.hunks)
        #expect(hunks.count == 2)

        // An untick made under another query does not survive into this one: its hunk ids meant other lines.
        model.search.rejected["A.swift"] = [hunks[0].id]
        model.search.query.text = "isSelected "
        #expect(model.search.rejected.isEmpty)
        model.search.query.text = "isSelected"

        model.search.rejected["A.swift"] = [hunks[1].id]
        model.replaceAll()
        try await settle(model)
        let written = try String(contentsOf: root.appending(path: "A.swift"), encoding: .utf8)
        #expect(written.contains("let isActive = 3") && written.contains("let isSelected = 17"))
        #expect(model.search.rejected.isEmpty)
    }

    @Test func aClosedFileIsWrittenInItsOwnEncodingAndAnOpenOneOnlyChangesInItsBuffer() async throws {
        let closed = Data([0xEF, 0xBB, 0xBF]) + Data("let isSelected = 1\r\nisSelected()\r\n".utf8)
        let (model, root) = try await workspace(["Closed.swift": closed, "Open.swift": Data("var isSelected = 2\n".utf8)])
        defer { try? FileManager.default.removeItem(at: root) }
        model.open(file: "Open.swift", pinned: true)
        for _ in 0..<50 where model.documents["Open.swift"]?.state != .ready { try await Task.sleep(for: .milliseconds(20)) }

        model.search.query.text = "isSelected"
        model.search.replacement = "isActive"
        model.rerunSearch()
        try await settle(model)
        #expect(model.search.results.count == 2)

        model.replaceAll()
        try await settle(model)
        #expect(try Data(contentsOf: root.appending(path: "Closed.swift")) == Data([0xEF, 0xBB, 0xBF]) + Data("let isActive = 1\r\nisActive()\r\n".utf8))
        let open = try #require(model.documents["Open.swift"])
        #expect(open.storage.string == "var isActive = 2\n" && open.isDirty)
        #expect(try String(contentsOf: root.appending(path: "Open.swift"), encoding: .utf8) == "var isSelected = 2\n")
        // The re-run finds nothing left (the open file's unsaved buffer is searched, not its stale file).
        #expect(model.search.results.isEmpty)
    }

    @Test func previewTicksLeaveTheCodeWhenAFirstRowWouldReachThem() {
        // FD51: at 520 pt the first hunk's row ran under its ✓ Keep; the ticks then take their own row.
        let old = "    @Environment(\\.ainkradSkin) private var skin\nlet thread: ThreadSummary\nlet isSelected: Bool\n"
        let diff = AinkradDiffEngine.compute(old: old, new: old.replacingOccurrences(of: "isSelected", with: "isActive"), path: "A.swift", context: 2)
        let skin = AinkradSkin.standard
        #expect(AinkradDiffReview.firstRowReachesTick(diff, width: 492, skin: skin))
        #expect(!AinkradDiffReview.firstRowReachesTick(diff, width: 900, skin: skin))
        #expect(!AinkradDiffReview.firstRowReachesTick(diff, width: nil, skin: skin))
    }
}
