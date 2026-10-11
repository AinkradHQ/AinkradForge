import Foundation
import Testing

@testable import ForgeFeature

@MainActor
@Suite("Forge store")
struct ForgeStoreTests {
    @Test func recentsAreNewestFirstDeduplicatedAndCapped() {
        let store = ForgeStore(documents: MemoryDocs())
        for index in 0..<(ForgeStore.recentLimit + 3) { store.noteOpened("/p\(index)") }
        store.noteOpened("/p5")
        #expect(store.document.recents.first?.path == "/p5")
        #expect(store.document.recents.count == ForgeStore.recentLimit)
        #expect(Set(store.document.recents.map(\.path)).count == ForgeStore.recentLimit)
        #expect(store.document.lastWorkspace == "/p5")
    }

    @Test func stateSurvivesAReload() {
        let docs = MemoryDocs()
        let store = ForgeStore(documents: docs)
        var tabs = Tabs()
        tabs.open("a.swift", pinned: true)
        store.update { $0.workspaces["/repo"] = .init(tabs: tabs, expanded: ["Sources"]) }
        let reloaded = ForgeStore(documents: docs)
        #expect(reloaded.document.workspaces["/repo"]?.tabs == tabs)
        #expect(reloaded.document.workspaces["/repo"]?.expanded == ["Sources"])
    }
}

@MainActor
@Suite("Launch payload")
struct LaunchTests {
    @Test func aFileOpensItsFolderWithTheFileInATab() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("forge-launch-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "let x = 1\n".write(to: folder.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
        let model = ForgeModel(store: ForgeStore(documents: MemoryDocs()))
        await model.start(launch: folder.appendingPathComponent("A.swift").path)
        #expect(model.workspace?.root.resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path)
        #expect(model.tabs.paths == ["A.swift"])
        #expect(model.tabs.preview == nil)
    }
}
