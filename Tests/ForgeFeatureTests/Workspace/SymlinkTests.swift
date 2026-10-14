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

    /// `real/` with `src/a.swift`, `lib/b.swift`, `link-file.swift → src/a.swift`, `link-dir → lib`, a loop
    /// `src/loop → ..` and a dangling link; `link/` is a link to `real/`.
    private func folder(git: Bool) throws -> (base: URL, real: URL, link: URL) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("forge-links-\(UUID().uuidString.prefix(8))")
        let real = base.appending(path: "real")
        let fm = FileManager.default
        for (path, text) in ["src/a.swift": "let a = isSelected\n", "lib/b.swift": "let b = isSelected\n"] {
            try fm.createDirectory(at: real.appending(path: path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: real.appending(path: path), atomically: true, encoding: .utf8)
        }
        try fm.createSymbolicLink(atPath: real.appending(path: "link-file.swift").path, withDestinationPath: "src/a.swift")
        try fm.createSymbolicLink(atPath: real.appending(path: "link-dir").path, withDestinationPath: "lib")
        try fm.createSymbolicLink(atPath: real.appending(path: "src/loop").path, withDestinationPath: "..")
        try fm.createSymbolicLink(atPath: real.appending(path: "dangling.swift").path, withDestinationPath: "nowhere.swift")
        let link = base.appending(path: "link")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: real.path)
        if git {
            for args in [["init", "-q"], ["add", "-A"], ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init"]] {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = args
                process.currentDirectoryURL = real
                try process.run()
                process.waitUntilExit()
            }
        }
        return (base, real, link)
    }

    @Test(arguments: [false, true])
    func linkedFilesAndFoldersAreListedAndSearchedAndALoopEnds(git: Bool) async throws {
        let (base, real, link) = try folder(git: git)
        defer { try? FileManager.default.removeItem(at: base) }
        let want = ["lib/b.swift", "link-dir/b.swift", "link-file.swift", "src/a.swift"]
        for root in [real, link] {
            let model = ForgeModel(store: ForgeStore(documents: MemoryDocs()))
            await model.start(launch: root.path)
            #expect(model.workspace?.files.sorted() == want, "git=\(git) root=\(root.lastPathComponent)")

            model.search.query.text = "isSelected"
            model.rerunSearch()
            for _ in 0..<100 {
                if case .done = model.search.status { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(model.search.results.map(\.path).sorted() == want)
        }
    }
}
