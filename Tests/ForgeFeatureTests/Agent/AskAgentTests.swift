import Foundation
import Testing

@testable import ForgeFeature

@MainActor
@Suite("Ask agent")
struct AskAgentTests {
    @Test func theSelectionsWholeLinesGoWithTheRequest() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("forge-ask-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "let a = 1\nlet b = 2\nlet c = 3\nlet d = 4\n".write(to: root.appending(path: "x.swift"), atomically: true, encoding: .utf8)
        let model = ForgeModel(store: ForgeStore(documents: MemoryDocs()))
        await model.start(launch: root.path)
        model.open(file: "x.swift", pinned: true)
        for _ in 0..<50 where model.documents["x.swift"]?.state != .ready { try await Task.sleep(for: .milliseconds(20)) }
        let document = try #require(model.documents["x.swift"])

        // From the middle of line 2 to the middle of line 3: both whole lines.
        document.selection = NSRange(location: 14, length: 8)
        model.beginAsk()
        var request = try #require(model.agent.ask)
        #expect(request.lines == 2...3)
        #expect(request.code == "let b = 2\nlet c = 3")
        request.prompt = "Make them constants."
        #expect(request.message == "In x.swift, lines 2–3:\n\n```swift\nlet b = 2\nlet c = 3\n```\n\nMake them constants.")
        // What Grimoire reads: its own payload kind, the folder and the request.
        let payload = try #require(request.payload(root: root))
        let decoded = try #require(try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: String])
        #expect(decoded == ["kind": "askAgent", "path": root.path(percentEncoded: false), "prompt": request.message])

        // Nothing selected: the caret's line.
        document.selection = NSRange(location: 31, length: 0)
        model.beginAsk()
        #expect(model.agent.ask?.lines == 4...4)
        #expect(model.agent.ask?.code == "let d = 4")

        // The caret at the very end of a last line with no newline after it: that line, not line 1 (E0 FD9).
        document.storage.replaceCharacters(in: NSRange(location: 39, length: 1), with: "")
        document.selection = NSRange(location: 39, length: 0)
        model.beginAsk()
        #expect(model.agent.ask?.lines == 4...4)
        #expect(model.agent.ask?.code == "let d = 4")
    }
}
