import Foundation
import Testing

@testable import ForgeFeature

@Suite("File operations")
struct FileOpsTests {
    private func root() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("forge-ops-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: url.appending(path: "Sources"), withIntermediateDirectories: true)
        try "a".write(to: url.appending(path: "Sources/A.swift"), atomically: true, encoding: .utf8)
        return url
    }

    private func exists(_ root: URL, _ path: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appending(path: path).path(percentEncoded: false))
    }

    @Test func namesAreValidated() {
        #expect(throws: FileOps.Failure.self) { try FileOps.validate("  ") }
        #expect(throws: FileOps.Failure.self) { try FileOps.validate("a/b") }
        #expect(throws: FileOps.Failure.self) { try FileOps.validate("..") }
        #expect((try? FileOps.validate("  B.swift ")) == "B.swift")
    }

    @Test func createRenameMoveAndRefuseClashes() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try FileOps.createFile(named: "B.swift", in: "Sources", root: root) == "Sources/B.swift")
        #expect(throws: FileOps.Failure.self) { try FileOps.createFile(named: "B.swift", in: "Sources", root: root) }
        #expect(try FileOps.createFolder(named: "Views", in: "Sources", root: root) == "Sources/Views")
        #expect(try FileOps.rename("Sources/B.swift", to: "C.swift", root: root) == "Sources/C.swift")
        #expect(throws: FileOps.Failure.self) { try FileOps.rename("Sources/C.swift", to: "A.swift", root: root) }
        #expect(try FileOps.move("Sources/C.swift", into: "Sources/Views", root: root) == "Sources/Views/C.swift")
        #expect(exists(root, "Sources/Views/C.swift") && !exists(root, "Sources/C.swift"))
        #expect(throws: FileOps.Failure.self) { try FileOps.move("Sources", into: "Sources/Views", root: root) }
    }

    @Test func duplicatesCountUp() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try FileOps.duplicate("Sources/A.swift", root: root) == "Sources/A copy.swift")
        #expect(try FileOps.duplicate("Sources/A.swift", root: root) == "Sources/A copy 2.swift")
    }

    @Test func trashIsNotADelete() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileOps.trash("Sources/A.swift", root: root)
        #expect(!exists(root, "Sources/A.swift"))
    }

    @Test func remapFollowsFilesAndFolders() {
        #expect(FileOps.remap("Sources/A.swift", from: "Sources/A.swift", to: "Sources/B.swift") == "Sources/B.swift")
        #expect(FileOps.remap("Sources/View/A.swift", from: "Sources/View", to: "Sources/Views") == "Sources/Views/A.swift")
        #expect(FileOps.remap("Sources/ViewModel.swift", from: "Sources/View", to: "Sources/Views") == nil)
    }
}
