import AppKit
import Foundation
import Testing

@testable import ForgeFeature

/// Split down (⌘K ⌘\), Join All Splits and Split Terminal (mockups 03, 04).
@MainActor
@Suite("Splits")
struct SplitsTests {
    @Test func splitDownIsTheCommandKChord() {
        #expect(ForgeCommand.splitDown.shortcut?.display == "⌘K ⌘\\")
        #expect(ForgeCommand.splitDown.shortcut?.afterCommandK == true)
        #expect(ForgeCommand.splitRight.shortcut?.display == "⌘\\")
        #expect(ForgeCommand.splitTerminal.shortcut?.display == "⇧⌘5")
        #expect(ForgeCommand.joinSplits.paletteTitle == "View: Join All Splits")
        #expect(ForgeCommand.splitTerminal.paletteTitle == "Terminal: Split Terminal")
        // The chord's second step is a key press read without its shift: ⇧⌘5 is "5", not "%".
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0, context: nil,
            characters: "%", charactersIgnoringModifiers: "%", isARepeat: false, keyCode: 23)
        #expect(event.flatMap { Shortcut(event: $0) } == ForgeCommand.splitTerminal.shortcut)
    }

    @Test func joinAllSplitsMovesEveryTabIntoOnePane() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("forge-join-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["a.swift", "b.swift", "c.swift"] {
            try "let x = 1\n".write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let model = ForgeModel(store: ForgeStore(documents: MemoryDocs()))
        await model.start(launch: folder.appendingPathComponent("a.swift").path)
        #expect(!model.availableCommands.contains(.joinSplits))
        model.splitEditor(stacked: true)
        model.open(file: "b.swift", pinned: true)
        model.open(file: "c.swift", pinned: false)
        #expect(model.availableCommands.contains(.joinSplits))
        model.run(.joinSplits)
        #expect(model.panes.count == 1 && !model.stacked)
        #expect(model.panes[0].paths == ["a.swift", "b.swift", "c.swift"])
        #expect(model.tabs.active == "c.swift")
        #expect(Set(model.documents.keys) == ["a.swift", "b.swift", "c.swift"])
    }

    @Test func splitTerminalShowsTwoSideBySide() throws {
        let drawer = TerminalDrawer()
        drawer.begin(root: URL(fileURLWithPath: NSTemporaryDirectory()))
        drawer.split()  // none yet: a shell, and one beside it
        #expect(drawer.tabs.count == 2 && drawer.isOpen)
        let pair = try #require(drawer.shownPair)
        #expect(pair == drawer.tabs.map(\.id) && drawer.active == pair[1])
        drawer.select(pair[0])
        #expect(drawer.shownPair == pair)
        drawer.add()
        #expect(drawer.shownPair == nil)  // a third terminal shows alone
        drawer.select(pair[1])
        drawer.close(pair[0])
        #expect(drawer.shownPair == nil && drawer.tabs.count == 2)
        drawer.end()
    }
}
