import Foundation
import Testing

@testable import ForgeFeature

@MainActor
@Suite("Split editor")
struct PanesTests {
    /// A model on a throwaway folder with three files, `a.swift` open.
    private func model() async throws -> (ForgeModel, URL) {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("forge-panes-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["a.swift", "b.swift", "c.swift"] {
            try "let x = 1\n".write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let model = ForgeModel(store: ForgeStore(documents: MemoryDocs()))
        await model.start(launch: folder.appendingPathComponent("a.swift").path)
        return (model, folder)
    }

    @Test func splittingShowsTheActiveFileInASecondPane() async throws {
        let (model, folder) = try await model()
        defer { try? FileManager.default.removeItem(at: folder) }
        model.splitEditor(stacked: false)
        #expect(model.panes.count == 2)
        #expect(model.panes[1].paths == ["a.swift"])
        #expect(model.activePane == 1)
        // One buffer for both panes.
        #expect(model.documents.count == 1)
    }

    @Test func closingAFileInOnePaneKeepsTheBufferTheOtherPaneShows() async throws {
        let (model, folder) = try await model()
        defer { try? FileManager.default.removeItem(at: folder) }
        model.open(file: "b.swift", pinned: true)
        model.splitEditor(stacked: false)  // pane 2 shows b.swift
        model.focus(pane: 0)
        model.close("b.swift")
        #expect(model.documents["b.swift"] != nil)
        #expect(model.panes[0].paths == ["a.swift"])
    }

    @Test func aPaneWhoseLastTabClosesGoesAway() async throws {
        let (model, folder) = try await model()
        defer { try? FileManager.default.removeItem(at: folder) }
        model.splitEditor(stacked: true)
        model.close("a.swift")  // pane 2's only tab
        #expect(model.panes.count == 1)
        #expect(model.activePane == 0)
        #expect(model.documents["a.swift"] != nil)
    }

    @Test func closingAPaneKeepsItsUnsavedFilesOpen() async throws {
        let (model, folder) = try await model()
        defer { try? FileManager.default.removeItem(at: folder) }
        model.splitEditor(stacked: false)
        model.open(file: "c.swift", pinned: true)
        model.didEdit("c.swift")
        model.closePane()
        #expect(model.panes.count == 1)
        #expect(model.panes[0].paths.contains("c.swift"))
        #expect(model.documents["c.swift"]?.isDirty == true)
    }

    @Test func theSplitIsRestoredWithTheWorkspace() async throws {
        let (model, folder) = try await model()
        defer { try? FileManager.default.removeItem(at: folder) }
        model.open(file: "b.swift", pinned: true)
        model.splitEditor(stacked: true)
        let reopened = ForgeModel(store: model.store)
        await reopened.start()
        #expect(reopened.panes.map(\.paths) == [["a.swift", "b.swift"], ["b.swift"]])
        #expect(reopened.stacked)
    }
}
