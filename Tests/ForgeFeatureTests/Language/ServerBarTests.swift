import Foundation
import Testing

@testable import ForgeFeature

/// E6: the language-server bar under the breadcrumb, and Initialize Repository.
@MainActor
@Suite("Server bar")
struct ServerBarTests {
    private func workspace(_ files: [String]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("forge-bar-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in files { try "x\n".write(to: root.appending(path: name), atomically: true, encoding: .utf8) }
        return root
    }

    private func open(_ path: String, in model: ForgeModel) async throws {
        model.open(file: path, pinned: true)
        for _ in 0..<100 where model.documents[path]?.state != .ready { try await Task.sleep(for: .milliseconds(20)) }
    }

    /// A language with no server gets a hint; ✕ hides it for the session, "Not for …" for good (saved), and either
    /// way only for that language. Plain text never gets one.
    @Test func theHintIsDismissedPerLanguage() async throws {
        let root = try workspace(["a.rb", "b.rb", "c.lua", "notes.txt"])
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ForgeStore(documents: MemoryDocs())
        let model = ForgeModel(store: store)
        await model.start(launch: root.path)
        for path in ["a.rb", "b.rb", "c.lua", "notes.txt"] { try await open(path, in: model) }

        let ruby = try #require(model.serverBar(for: "a.rb"))
        #expect(ruby.kind == .missing && ruby.language == "Ruby" && ruby.spec == nil)
        #expect(ruby.message.hasPrefix("No language server for Ruby"))
        #expect(model.serverBar(for: "notes.txt") == nil)

        model.dismissServerHint("Ruby", forever: false)
        #expect(model.serverBar(for: "b.rb") == nil)
        #expect(model.serverBar(for: "c.lua")?.language == "Lua")
        #expect(store.document.quietLanguages == nil)

        model.dismissServerHint("Lua", forever: true)
        model.dismissServerHint("Lua", forever: true)
        #expect(model.serverBar(for: "c.lua") == nil)
        #expect(store.document.quietLanguages == ["Lua"])
        // A new window (session) forgets ✕ but keeps "Not for Lua".
        let next = ForgeModel(store: store)
        await next.start(launch: root.path)
        try await open("a.rb", in: next)
        try await open("c.lua", in: next)
        #expect(next.serverBar(for: "a.rb") != nil)
        #expect(next.serverBar(for: "c.lua") == nil)
    }

    /// A known server that is missing says which package installs it (FD25's servers included).
    @Test func aMissingServerNamesItsInstall() async throws {
        let root = try workspace(["ci.yml", "site.css"])
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ForgeModel(store: ForgeStore(documents: MemoryDocs()))
        model.setServerPath("yaml-language-server", "/nonexistent/forge-bar")
        model.setServerPath("vscode-css-language-server", "/nonexistent/forge-bar")
        await model.start(launch: root.path)
        try await open("ci.yml", in: model)
        try await open("site.css", in: model)
        let yaml = try #require(model.serverBar(for: "ci.yml"))
        #expect(yaml.kind == .missing && yaml.language == "YAML" && yaml.spec?.id == "yaml-language-server")
        #expect(yaml.message.contains("npm i -g yaml-language-server"))
        #expect(model.serverBar(for: "site.css")?.message.contains("npm i -g vscode-langservers-extracted") == true)
        model.dismissServerHint("YAML", forever: false)
        #expect(model.serverBar(for: "ci.yml") == nil)
    }

    /// Initialize Repository turns a plain folder into a repository: the workspace gets its (unborn) branch.
    @Test func initializeRepositoryRunsGitInit() async throws {
        let root = try workspace(["a.txt"])
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ForgeModel(store: ForgeStore(documents: MemoryDocs()))
        await model.start(launch: root.path)
        for _ in 0..<100 where model.workspace?.isLoading != false { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.workspace?.branch == nil)
        model.initializeRepository()
        for _ in 0..<150 where model.workspace?.branch == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.workspace?.branch?.isEmpty == false)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: ".git").path))
    }
}
