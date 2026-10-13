import AinkradAppKit
import Foundation
import SwiftUI
import Testing

@testable import ForgeFeature

/// The command palette's ⌘K rebind and the commands other Ainkrad apps contribute (mockup 03).
@MainActor
@Suite("Keybindings")
struct KeybindingsTests {
    /// A host launcher that says which apps are installed and enabled.
    private final class Launcher: PluginAppLauncher, PluginAppAvailability {
        var installed: Set<String>
        init(_ installed: Set<String>) { self.installed = installed }
        func open(appID: String, payload: String?) {}
        func takePendingLaunch() -> String? { nil }
        func isAppAvailable(appID: String) -> Bool { installed.contains(appID) }
    }

    @Test func aRebindIsSavedShownAndCanBeUndone() throws {
        let docs = MemoryDocs()
        let model = ForgeModel(store: ForgeStore(documents: docs))
        let f5 = Shortcut(key: Character("\u{F708}"), modifiers: [])
        #expect(model.rejection(of: f5, for: .commandPalette) == nil)
        model.rebind(.commandPalette, to: f5)
        #expect(model.shortcut(for: .commandPalette)?.display == "F5")
        #expect(Palette.items(for: ">show all commands", model: model).first?.value == "F5")
        // Saved: a new window on the same store has it.
        #expect(ForgeModel(store: ForgeStore(documents: docs)).shortcut(for: .commandPalette) == f5)
        model.rebind(.commandPalette, to: nil)
        #expect(model.shortcut(for: .commandPalette) == ForgeCommand.commandPalette.shortcut)
        #expect(model.store.document.shortcuts == nil)
    }

    @Test func tooltipsAndLabelsFollowARebind() {
        let model = ForgeModel(store: ForgeStore(documents: MemoryDocs()))
        #expect(model.titled("New Terminal", .newTerminal) == "New Terminal (⌃⇧`)")
        #expect(model.labelled("✓ Keep", .keepChange) == "✓ Keep ⌘↵")
        model.rebind(.newTerminal, to: Shortcut(key: "t", modifiers: [.control, .option]))
        #expect(model.titled("New Terminal", .newTerminal) == "New Terminal (⌃⌥T)")
        #expect(model.titled("Close Workspace", .closeWorkspace) == "Close Workspace")
    }

    @Test func chordsTheHostMacOSOrAnotherCommandOwnAreRefused() {
        let model = ForgeModel(store: ForgeStore(documents: MemoryDocs()))
        func why(_ key: Character, _ modifiers: EventModifiers) -> String? {
            model.rejection(of: Shortcut(key: key, modifiers: modifiers), for: .splitRight)
        }
        #expect(why("k", .command)?.contains("Ainkrad") == true)
        #expect(why("a", [.command, .shift])?.contains("Ainkrad") == true)
        #expect(why("3", .option)?.contains("Ainkrad") == true)
        #expect(why("q", .command)?.contains("macOS") == true)
        #expect(why("p", .command) == "⌘P already runs “Go: Go to File…”.")
        #expect(why("x", []) != nil && why("x", .shift) != nil)
        #expect(why("j", [.command, .option]) == nil)
        // A command's own default is always fine, even one the host would otherwise keep (Forge claims ⌘W).
        #expect(model.rejection(of: Shortcut(key: "w", modifiers: .command), for: .closeTab) == nil)
        // A rebound command's chord is taken; its old default is free.
        model.rebind(.splitRight, to: Shortcut(key: "j", modifiers: [.command, .option]))
        #expect(model.rejection(of: Shortcut(key: "j", modifiers: [.command, .option]), for: .saveAll) != nil)
        #expect(model.rejection(of: Shortcut(key: "\\", modifiers: .command), for: .saveAll) == nil)
    }

    @Test func shortcutsRoundTripThroughTheStore() throws {
        for shortcut in [ForgeCommand.splitDown.shortcut, ForgeCommand.findReferences.shortcut, ForgeCommand.commandPalette.shortcut] {
            let data = try JSONEncoder().encode(shortcut)
            #expect(try JSONDecoder().decode(Shortcut.self, from: data) == shortcut)
        }
    }

    /// Open in Git Mage and Rune's terminal are listed only while their app is installed and enabled; a host that
    /// cannot say keeps them.
    @Test func otherAppsCommandsFollowWhatIsInstalled() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("forge-apps-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let launcher = Launcher(["gitmage"])
        let model = ForgeModel(store: ForgeStore(documents: MemoryDocs()), apps: launcher)
        await model.open(folder: folder)
        #expect(model.availableCommands.contains(.openInGitMage))
        #expect(!model.availableCommands.contains(.openTerminal))
        launcher.installed = ["rune"]
        #expect(!model.availableCommands.contains(.openInGitMage) && model.availableCommands.contains(.openTerminal))
        #expect(ForgeCommand.openInGitMage.paletteTitle == "Git: Open in Git Mage")
        #expect(ForgeCommand.openInGitMage.shortcut?.display == "⇧⌘G")
        #expect(ForgeCommand.askAgent.paletteTitle == "Agent: Ask Grimoire about Selection")
    }
}
