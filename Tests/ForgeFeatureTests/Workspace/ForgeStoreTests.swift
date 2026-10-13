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

    /// FD37: a launch into another folder asks about unsaved files and running terminals like any other leave,
    /// opens its file at its line once the user goes on, and is dropped when they stay.
    @Test func aLaunchElsewhereAsksBeforeLeavingAndLandsAfter() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("forge-leave-\(UUID().uuidString.prefix(8))")
        let first = base.appendingPathComponent("a"), second = base.appendingPathComponent("b")
        for folder in [first, second] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: base) }
        try "let x = 1\n".write(to: first.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        try "1\n2\n3\n".write(to: second.appendingPathComponent("b.swift"), atomically: true, encoding: .utf8)
        let launch = #"{"kind":"openDocument","path":"\#(second.appendingPathComponent("b.swift").path)","line":3}"#
        let model = ForgeModel(store: ForgeStore(documents: MemoryDocs()))
        await model.start(launch: first.appendingPathComponent("a.swift").path)
        for _ in 0..<50 where model.documents["a.swift"]?.state != .ready { try await Task.sleep(for: .milliseconds(20)) }
        model.documents["a.swift"]?.storage.mutableString.append("let y = 2\n")
        model.didEdit("a.swift")

        // Unsaved: asked first; staying keeps the buffer and drops the launch.
        await model.start(launch: launch)
        guard case .open(let url, let then)? = model.pendingLeave else { Issue.record("no leave prompt"); return }
        #expect(url.standardizedFileURL.path == second.standardizedFileURL.path)
        #expect(then == ForgeLaunch(path: second.appendingPathComponent("b.swift").path, line: 3))
        model.resolvePendingLeave(saveAll: nil)
        #expect(model.workspace?.root.path == first.path)
        #expect(model.documents["a.swift"]?.isDirty == true)

        // Saved, but a task runs: the drawer asks; going on opens b.swift at line 3.
        model.saveActive()
        _ = model.terminals.add(command: "sleep 30", title: "dev server")
        await model.start(launch: launch)
        #expect(model.pendingLeave == nil)
        let leave = try #require(model.terminals.confirmingLeave?.leave)
        #expect(model.workspace?.root.path == first.path)
        model.terminals.confirmingLeave = nil
        leave()
        for _ in 0..<100 where model.tabs.active != "b.swift" { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.workspace?.root.path == second.path)
        #expect(model.tabs.active == "b.swift")
        #expect(model.pendingLine == 3)
    }
}
