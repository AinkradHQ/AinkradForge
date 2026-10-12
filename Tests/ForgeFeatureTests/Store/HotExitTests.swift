import Foundation
import Testing

@testable import ForgeFeature

@MainActor
@Suite("Unsaved buffers across a quit")
struct HotExitTests {
    @Test func anUnsavedBufferComesBackUnsavedAfterAQuit() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("forge-hot-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("a.swift")
        try "let x = 1\n".write(to: file, atomically: true, encoding: .utf8)
        let store = ForgeStore(documents: MemoryDocs())

        let model = ForgeModel(store: store)
        await model.start(launch: file.path)
        for _ in 0..<50 where model.documents["a.swift"]?.state != .ready { try await Task.sleep(for: .milliseconds(20)) }
        model.documents["a.swift"]?.storage.mutableString.append("let y = 2\n")
        model.didEdit("a.swift")
        model.backupUnsaved()

        let relaunched = ForgeModel(store: store)
        await relaunched.start()
        for _ in 0..<50 where relaunched.documents["a.swift"]?.state != .ready { try await Task.sleep(for: .milliseconds(20)) }
        let document = try #require(relaunched.documents["a.swift"])
        #expect(document.storage.string == "let x = 1\nlet y = 2\n")
        #expect(document.isDirty)
        // The disk is untouched, and the backup is used once.
        #expect(try String(contentsOf: file, encoding: .utf8) == "let x = 1\n")
        #expect(store.unsaved(in: folder.path(percentEncoded: false)).isEmpty)
    }
}
