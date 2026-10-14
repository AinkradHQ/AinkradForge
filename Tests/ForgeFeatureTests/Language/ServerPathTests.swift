import AppKit
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

    /// Settings' field saves when typing pauses, not per keystroke: a space typed mid-path stays, `~` stays as typed
    /// in the field, and the server is pointed at the path once (E1D4 FD58).
    @Test func typingAServerPathCommitsOnlyWhenTypingPauses() async throws {
        let model = ForgeModel(store: ForgeStore(documents: MemoryDocs()))
        var typed = ""
        for character in "~/My Tools/sourcekit-lsp" {
            typed.append(character)
            model.typeServerPath("sourcekit-lsp", typed, after: .milliseconds(200))
            #expect(model.serverPathField("sourcekit-lsp") == typed)
            #expect(model.editorSettings.serverPaths["sourcekit-lsp"] == nil)
        }
        #expect(model.serverPathField("sourcekit-lsp") == "~/My Tools/sourcekit-lsp")
        for _ in 0..<100 where model.editorSettings.serverPaths["sourcekit-lsp"] == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.editorSettings.serverPaths["sourcekit-lsp"] == NSHomeDirectory() + "/My Tools/sourcekit-lsp")
        #expect(model.languages.overrides["sourcekit-lsp"] == NSHomeDirectory() + "/My Tools/sourcekit-lsp")
        #expect(model.serverPathField("sourcekit-lsp") == "~/My Tools/sourcekit-lsp")

        // Reset clears the field at once, and a commit still pending can't bring the old text back.
        model.typeServerPath("sourcekit-lsp", "/x ", after: .milliseconds(100))
        model.setServerPath("sourcekit-lsp", "")
        try await Task.sleep(for: .milliseconds(250))
        #expect(model.serverPathField("sourcekit-lsp") == "" && model.editorSettings.serverPaths["sourcekit-lsp"] == nil)
    }

    /// E1D5 FD71: quitting (or closing the window) within the pause lost the path typed.
    @Test func aPathTypedJustBeforeQuittingIsSaved() async throws {
        let docs = MemoryDocs()
        let model = ForgeModel(store: ForgeStore(documents: docs))
        model.typeServerPath("gopls", "~/go/bin/gopls ", after: .seconds(30))
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        #expect(model.editorSettings.serverPaths["gopls"] == NSHomeDirectory() + "/go/bin/gopls")
        // Saved to the store, so the next launch has it.
        #expect(ForgeModel(store: ForgeStore(documents: docs)).editorSettings.serverPaths["gopls"] == NSHomeDirectory() + "/go/bin/gopls")
    }

    /// With no server for the file, or its server missing, the window says so instead of "0 issues" (E1D1 FD33).
    @Test func aFileWithoutARunningServerSaysWhy() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("forge-gap-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a.swift", "b.rb"] { try "x\n".write(to: root.appending(path: name), atomically: true, encoding: .utf8) }
        let model = ForgeModel(store: ForgeStore(documents: MemoryDocs()))
        #expect(model.activeServerGap == nil)
        model.setServerPath("sourcekit-lsp", "/nonexistent/forge-gap")
        await model.start(launch: root.path)
        model.open(file: "b.rb", pinned: true)
        #expect(model.activeServerGap == "No language server covers this file.")
        model.open(file: "a.swift", pinned: true)
        for _ in 0..<100 where model.activeServerGap == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.activeServerGap?.hasPrefix("sourcekit-lsp is not installed") == true)
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
