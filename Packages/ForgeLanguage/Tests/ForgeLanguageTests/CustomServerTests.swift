import Foundation
import Testing

@testable import ForgeLanguage

/// FP112: a server the user set up for a language Forge has none for — routed by extension, run with its
/// arguments, under the same crash/restart policy as Forge's own.
@MainActor
@Suite("Custom servers")
struct CustomServerTests {
    private func ruby(_ path: String, arguments: [String] = ["stdio"]) -> ServerSpec {
        ServerSpec(
            id: "custom-ruby", language: "Ruby", command: (path as NSString).lastPathComponent, arguments: arguments,
            languageIDs: ["rb": "ruby", "rake": "ruby"], installHint: "Set its path again.")
    }

    @Test func aCustomServerServesItsExtensionsAfterForgesOwn() {
        let hub = LanguageHub()
        #expect(hub.server(for: "deploy/release.rb") == nil)
        hub.setCustom([ruby("/opt/bin/solargraph")])
        #expect(hub.server(for: "deploy/release.rb")?.spec.id == "custom-ruby")
        #expect(hub.server(for: "Rakefile.rake")?.languageID == "ruby")
        #expect(hub.server(for: "main.swift")?.spec.id == "sourcekit-lsp")
        #expect(LanguageRegistry.server(for: "release.rb") == nil, "the static registry keeps Forge's own only")
    }

    @Test func itRunsWithItsArgumentsAndCrashesLikeAnyOther() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("forge-custom-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let seen = dir.appending(path: "args.txt")
        let script = dir.appending(path: "ruby-server")
        try "#!/bin/sh\necho \"$@\" >> '\(seen.path)'\nkill -SEGV $$\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let hub = LanguageHub()
        let spec = ruby(script.path, arguments: ["stdio", "--verbose"])
        hub.setCustom([spec])
        hub.overrides[spec.id] = script.path
        hub.begin(root: dir)
        hub.opened(path: "release.rb", text: "puts 1\n")
        for _ in 0..<100 where hub.statuses[spec.id] != .crashed("signal 11 (SEGV)") { try await Task.sleep(for: .milliseconds(50)) }
        #expect(hub.statuses[spec.id] == .crashed("signal 11 (SEGV)"))
        #expect(try String(contentsOf: seen, encoding: .utf8) == "stdio --verbose\nstdio --verbose\n", "started twice, then left down")

        // Changing its arguments stops it; the next file starts it as it is now.
        hub.setCustom([ruby(script.path, arguments: ["--stdio"])])
        #expect(hub.statuses[spec.id] == nil)
        hub.setCustom([])
        #expect(hub.server(for: "release.rb") == nil)
        hub.end()
    }
}
