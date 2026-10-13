import ForgeLanguage
import Foundation
import Testing

@testable import ForgeFeature

/// FP112: Set server path… for a language Forge has no server for — kept in settings, run by the hub.
@MainActor
@Suite("Custom server setting")
struct CustomServerSettingTests {
    @Test func aServerSetForRubyRunsItsFilesAndIsKept() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("forge-ruby-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "puts 1\n".write(to: root.appending(path: "release.rb"), atomically: true, encoding: .utf8)
        // Stays up without answering: "starting" is enough to know it was run.
        let script = root.appending(path: "ruby-lsp.sh")
        try "#!/bin/sh\necho \"$@\" > '\(root.appending(path: "args").path)'\ncat > /dev/null\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let docs = MemoryDocs()
        let model = ForgeModel(store: ForgeStore(documents: docs))
        await model.start(launch: root.path)
        model.open(file: "release.rb", pinned: true)
        for _ in 0..<100 where model.documents["release.rb"]?.state != .ready { try await Task.sleep(for: .milliseconds(20)) }
        let bar = try #require(model.serverBar(for: "release.rb"))
        #expect(bar.kind == .missing && bar.spec == nil && bar.language == "Ruby" && bar.path == "release.rb")

        model.setCustomServer(forFileAt: "release.rb", executable: script.path, arguments: " stdio  --verbose ")
        let server = try #require(model.editorSettings.customServers.first)
        #expect(server.id == "custom-ruby" && server.arguments == ["stdio", "--verbose"] && server.extensions.contains("rb"))
        #expect(model.editorSettings.serverPaths["custom-ruby"] == script.path)
        #expect(model.languages.statuses["custom-ruby"] == .starting)
        #expect(model.serverBar(for: "release.rb") == nil, "the hint goes once a server runs")
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: root.appending(path: "args").path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try String(contentsOf: root.appending(path: "args"), encoding: .utf8) == "stdio --verbose\n")

        // Kept: a new window on the same saved state serves Ruby the same way.
        let again = ForgeModel(store: ForgeStore(documents: docs))
        #expect(again.editorSettings.customServers == [server])
        again.beginLanguages(root: root)
        #expect(again.languages.server(for: "release.rb")?.spec.id == "custom-ruby")
        again.languages.end()

        model.removeCustomServer("custom-ruby")
        #expect(model.editorSettings.customServers.isEmpty && model.editorSettings.serverPaths["custom-ruby"] == nil)
        #expect(model.serverBar(for: "release.rb")?.spec == nil)
        model.languages.end()
    }
}
