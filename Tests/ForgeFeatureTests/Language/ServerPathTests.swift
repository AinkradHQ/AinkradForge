import ForgeEditor
import Foundation
import Testing

@testable import ForgeFeature

@MainActor
@Suite("Server paths")
struct ServerPathTests {
    @Test func aPathIsKeptExpandedAndEmptyMeansThePath() {
        let model = ForgeModel(store: ForgeStore(documents: MemoryDocs()))
        model.setServerPath("gopls", "  ~/go/bin/gopls ")
        #expect(model.editorSettings.serverPaths["gopls"] == NSHomeDirectory() + "/go/bin/gopls")
        #expect(model.languages.overrides["gopls"] == NSHomeDirectory() + "/go/bin/gopls")
        model.setServerPath("gopls", "")
        #expect(model.editorSettings.serverPaths["gopls"] == nil)
        #expect(model.languages.overrides["gopls"] == nil)
    }
}

@MainActor
@Suite("Editor polish")
struct EditorPolishTests {
    @Test func aDefinitionOpensInTheSplitWhenAsked() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("forge-split-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["A.swift", "B.swift"] { try "x\n".write(to: root.appending(path: name), atomically: true, encoding: .utf8) }
        let model = ForgeModel(store: ForgeStore(documents: MemoryDocs()))
        await model.start(launch: root.path)
        model.open(file: "A.swift", pinned: true)
        model.open(EditorLinkFixture.link(root: root, "B.swift"), inSplit: true)
        #expect(model.panes.count == 2)
        #expect(model.activePane == 1 && model.tabs.active == "B.swift")
        #expect(model.panes[0].active == "A.swift")
    }

    @Test func escClosesHintsAndIsOnlyClaimedWhileOneShows() {
        let model = ForgeModel(store: ForgeStore(documents: MemoryDocs()))
        #expect(!model.availableCommands.contains(.closeHints))
        model.agent.showingWas = true
        #expect(model.hintShown)
        model.closeHints()
        #expect(!model.hintShown)
        #expect(ForgeCommand.closeHints.shortcut?.display == "Esc")
    }
}

enum EditorLinkFixture {
    static func link(root: URL, _ path: String) -> EditorLink {
        EditorLink(path: root.appending(path: path).path(percentEncoded: false), line: 1, label: path, preview: "")
    }
}
