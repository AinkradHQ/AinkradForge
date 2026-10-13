import AinkradAppKit
import Foundation
import Testing

@testable import ForgeFeature

@Suite("Commands")
struct CommandsTests {
    @Test func keycapsPrintModifiersInMacOrder() {
        #expect(ForgeCommand.commandPalette.shortcut?.display == "⇧⌘P")
        #expect(ForgeCommand.saveAll.shortcut?.display == "⌥⌘S")
        #expect(ForgeCommand.showChanges.shortcut?.display == "⌃⇧G")
        #expect(ForgeCommand.goToDefinition.shortcut?.display == "F12")
        #expect(ForgeCommand.findReferences.shortcut?.display == "⇧F12")
        #expect(ForgeCommand.previousProblem.shortcut?.display == "⇧F8")
    }

    @Test func noTwoCommandsShareAChord() {
        let chords = ForgeCommand.allCases.compactMap(\.shortcut).map(\.display)
        #expect(Set(chords).count == chords.count)
    }

    @Test func availabilityFollowsWhatIsOpen() {
        let none = ForgeCommand.available(hasWorkspace: false, hasFile: false)
        #expect(none.contains(.openFolder) && !none.contains(.save) && !none.contains(.showChanges))
        let workspace = ForgeCommand.available(hasWorkspace: true, hasFile: false)
        #expect(workspace.contains(.showChanges) && !workspace.contains(.goToLine))
        #expect(!ForgeCommand.available(hasWorkspace: true, hasFile: true).contains(.closePane))
        #expect(ForgeCommand.available(hasWorkspace: true, hasFile: true, hasSplit: true, inAgentChange: true, agentFile: true, hintShown: true).count == ForgeCommand.allCases.count)
    }

    /// F8 / ⇧F8 step past the caret's line, across files, and wrap (E1D2 FD40).
    @MainActor @Test func nextProblemStepsPastTheCaretAndWraps() {
        let issues = [("a.swift", 3), ("a.swift", 9), ("b.swift", 0)]
        #expect(ForgeModel.problem(in: issues, after: ("a.swift", 3), backward: false) == 1)
        #expect(ForgeModel.problem(in: issues, after: ("a.swift", 9), backward: false) == 2)
        #expect(ForgeModel.problem(in: issues, after: ("b.swift", 0), backward: false) == 0)
        #expect(ForgeModel.problem(in: issues, after: ("a.swift", 3), backward: true) == 2)
        #expect(ForgeModel.problem(in: issues, after: ("a.swift", 5), backward: true) == 0)
        #expect(ForgeModel.problem(in: issues, after: nil, backward: false) == 0)
        #expect(ForgeModel.problem(in: [], after: nil, backward: false) == nil)
    }

    /// A narrow window starts without the sidebar; asking for a sidebar tab brings it back (E1D2 FD41).
    @MainActor @Test func aNarrowWindowHidesTheSidebarUntilATabIsAskedFor() {
        let model = ForgeModel(store: ForgeStore(documents: MemoryDocs()))
        #expect(model.isSidebarShown)
        model.windowIsNarrow = true
        #expect(!model.isSidebarShown)
        model.sideTab = .search
        #expect(model.isSidebarShown)
        #expect(ForgeCommand.toggleSidebar.shortcut?.display == "⌘0")
    }

    @Test func commandSearchMatchesTitleWords() {
        let found = ForgeCommand.matching("rev", in: ForgeCommand.allCases)
        #expect(found.first == .revealInTree)
        #expect(ForgeCommand.matching("", in: [.save, .closeTab]) == [.save, .closeTab])
    }
}

@MainActor
@Suite("Palette")
struct PaletteTests {
    @Test func theFirstCharacterPicksTheMode() {
        let model = ForgeModel(store: ForgeStore(documents: MemoryDocs()))
        #expect(Palette.items(for: ">open", model: model).first?.payload == .command(.openFolder))
        // No workspace: no files, and no line to go to.
        #expect(Palette.items(for: "", model: model).isEmpty)
        #expect(Palette.items(for: ":12", model: model).isEmpty)
    }

    /// ⌃⌘O (mockups 01, 05, 19): the recent workspaces as a palette, newest first, filtered by what is typed.
    @Test func switchWorkspaceListsTheRecentWorkspaces() {
        let model = ForgeModel(store: ForgeStore(documents: MemoryDocs()))
        model.store.noteOpened("/p/AinkradForge", at: Date(timeIntervalSince1970: 1))
        model.store.noteOpened("/p/Ainkrad", at: Date(timeIntervalSince1970: 2))
        #expect(ForgeCommand.switchWorkspace.shortcut?.display == "⌃⌘O")
        #expect(!ForgeModel.reserved(Shortcut(key: "o", modifiers: [.control, .command])))
        model.run(.switchWorkspace)
        #expect(model.palette == "~")
        #expect(Palette.items(for: "~", model: model).map(\.payload) == [.workspace("/p/Ainkrad"), .workspace("/p/AinkradForge")])
        #expect(Palette.items(for: "~frg", model: model).map(\.title) == ["AinkradForge"])
    }

    @Test func theModeCharacterIsSplitOffTheQuery() {
        #expect(Palette.split(">open") == (">", "open"))
        #expect(Palette.split(":12") == (":", "12"))
        #expect(Palette.split("side") == ("", "side"))
    }
}

@MainActor
@Suite("Saved state compatibility")
struct CompatibilityTests {
    /// State saved before `recentFiles` existed must still load — a decode failure sets the whole document aside.
    @Test func stateWithoutRecentFilesStillDecodes() throws {
        let old = #"{"recents":[],"workspaces":{"/repo":{"tabs":{"paths":["a.swift"],"active":"a.swift"},"expanded":["Sources"]}}}"#
        let docs = MemoryDocs()
        docs.storage[ForgeStore.key] = Data(old.utf8)
        let store = ForgeStore(documents: docs)
        #expect(store.document.workspaces["/repo"]?.tabs.paths == ["a.swift"])
        #expect(store.document.workspaces["/repo"]?.recentFiles == nil)
    }

    @Test func aLaunchIntentOpensItsPath() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("forge-intent-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = ForgeModel(store: ForgeStore(documents: MemoryDocs()))
        await model.start(launch: AinkradLaunchIntent(kind: "openDirectory", path: folder.path).json)
        #expect(model.workspace?.root.resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path)
    }
}
