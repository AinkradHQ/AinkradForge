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
        #expect(ForgeCommand.available(hasWorkspace: true, hasFile: true, hasSplit: true).count == ForgeCommand.allCases.count)
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
