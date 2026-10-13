import ForgeLanguage
import Foundation
import Testing

@testable import ForgeFeature

/// ⌥-hover: the quick help only — the symbol's documentation without the issue under the pointer (mockup 09).
/// End to end with the real sourcekit-lsp; skipped where it is not installed.
@MainActor
@Suite("Quick help")
struct QuickHelpTests {
    @Test func optionHoverLeavesTheIssuesOut() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("forge-quickhelp-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // `bump("x")` is an error on a symbol with documentation.
        let text = "/// Adds one.\nfunc bump(_ n: Int) -> Int { n + 1 }\nlet a = bump(\"x\")\n"
        try text.write(to: folder.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        let model = ForgeModel(store: ForgeStore(documents: MemoryDocs()))
        await model.start(launch: folder.appendingPathComponent("main.swift").path)
        for _ in 0..<150 where model.languages.issues["main.swift"]?.isEmpty ?? true { try await Task.sleep(for: .milliseconds(100)) }
        guard model.languages.statuses["sourcekit-lsp"] != .notInstalled else { return }
        #expect(model.languages.issues["main.swift"]?.isEmpty == false)
        // At the issue's own start.
        let issue = try #require(model.languages.issues["main.swift"]?.first)
        let hit = (offset: LineIndex(text).range(from: issue.start, to: issue.end).location, rect: CGRect.zero)
        await model.hover(pane: 0, path: "main.swift", at: hit, quickHelpOnly: false)
        #expect(model.hover?.issues.isEmpty == false)
        model.hover = nil
        await model.hover(pane: 0, path: "main.swift", at: hit, quickHelpOnly: true)
        #expect(model.hover == nil || model.hover?.issues.isEmpty == true)
        // On the documented name, ⌥ keeps the documentation.
        let name = (text as NSString).range(of: "bump(\"x\")").location + 1
        await model.hover(pane: 0, path: "main.swift", at: (name, .zero), quickHelpOnly: true)
        #expect(model.hover?.markdown?.contains("Adds one") == true)
        #expect(model.hover?.issues.isEmpty == true)
    }
}
