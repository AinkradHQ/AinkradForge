import Foundation
import Testing

@testable import ForgeFeature

/// Links in and to a workspace (E1D5 FD65, FD66).
@MainActor
@Suite("Symlinks")
struct SymlinkTests {
    /// A plain folder opened through a link listed nothing: the enumerator does not descend into a link (FD65).
    @Test func aPlainFolderOpenedThroughALinkLoadsItsFiles() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("forge-links-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: base) }
        let real = base.appending(path: "real")
        try FileManager.default.createDirectory(at: real.appending(path: "src"), withIntermediateDirectories: true)
        try "let a = 1\n".write(to: real.appending(path: "src/a.swift"), atomically: true, encoding: .utf8)
        try "b\n".write(to: real.appending(path: "b.txt"), atomically: true, encoding: .utf8)
        let link = base.appending(path: "link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: real.path)

        let model = ForgeModel(store: ForgeStore(documents: MemoryDocs()))
        await model.start(launch: link.path)
        #expect(model.workspace?.files.sorted() == ["b.txt", "src/a.swift"])
    }
}
