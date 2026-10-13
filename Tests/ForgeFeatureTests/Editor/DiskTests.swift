import Foundation
import Testing

@testable import ForgeFeature

@MainActor
@Suite("Documents and the disk")
struct DiskTests {
    private func file(_ bytes: Data) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("forge-disk-\(UUID().uuidString.prefix(8)).txt")
        try bytes.write(to: url)
        return url
    }

    /// Bumps the modification date so a rewrite inside the same second still reads as a change.
    private func touch(_ url: URL, _ bytes: Data) throws {
        try bytes.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
    }

    @Test func aSaveWritesTheFileBackAsItWas() async throws {
        let original = Data([0xEF, 0xBB, 0xBF]) + Data("one\r\ntwo\r\n".utf8)
        let url = try file(original)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = EditorDocument(url: url)
        await document.load()
        #expect(document.format == TextFormat(encoding: .utf8BOM, lineEnding: .crlf))
        // The buffer is LF (CodeEditTextView draws CRLF as an extra row); the file keeps its CRLF.
        #expect(document.storage.string == "one\ntwo\n")
        document.didEdit()
        try document.save()
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func convertingLineEndingsChangesWhatTheNextSaveWrites() async throws {
        let url = try file(Data("a\nb\n".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let document = EditorDocument(url: url)
        await document.load()
        document.convertLineEndings(to: .crlf)
        #expect(document.isDirty)
        try document.save()
        #expect(try Data(contentsOf: url) == Data("a\r\nb\r\n".utf8))
    }

    @Test func ourOwnSaveIsNotAnOutsideChange() async throws {
        let url = try file(Data("a\n".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let document = EditorDocument(url: url)
        await document.load()
        document.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "b")
        document.didEdit()
        try document.save()
        await document.checkDisk()
        #expect(document.conflict == nil && document.revision == 0)
    }

    /// Undoing back to the saved text clears the unsaved dot; a format change keeps it (E0 FD12).
    @Test func editingBackToTheSavedTextIsClean() async throws {
        let url = try file(Data("a\n".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let document = EditorDocument(url: url)
        await document.load()
        document.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "b")
        document.didEdit()
        #expect(document.isDirty)
        document.storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "")
        document.didEdit()
        #expect(!document.isDirty)
        document.convertLineEndings(to: .crlf)
        document.didEdit()
        #expect(document.isDirty)
        try document.save()
        #expect(!document.isDirty)
    }

    @Test func anOutsideChangeReloadsACleanBuffer() async throws {
        let url = try file(Data("old\n".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let document = EditorDocument(url: url)
        await document.load()
        try touch(url, Data("new\n".utf8))
        await document.checkDisk()
        #expect(document.storage.string == "new\n")
        #expect(document.revision == 1)
        #expect(document.conflict == nil)
    }

    @Test func anOutsideChangeToADirtyBufferAsksAndKeepsTheEdits() async throws {
        let url = try file(Data("old\n".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let document = EditorDocument(url: url)
        await document.load()
        document.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "mine ")
        document.didEdit()
        try touch(url, Data("theirs\n".utf8))
        await document.checkDisk()
        #expect(document.conflict == .modified)
        #expect(document.storage.string == "mine old\n")
        await document.resolveConflict(reload: true)
        #expect(document.storage.string == "theirs\n" && document.conflict == nil && !document.isDirty)
    }

    @Test func aDeletedFileKeepsItsTextAndSavingWritesItBack() async throws {
        let url = try file(Data("keep me\n".utf8))
        let document = EditorDocument(url: url)
        await document.load()
        try FileManager.default.removeItem(at: url)
        await document.checkDisk()
        #expect(document.conflict == .deleted)
        await document.resolveConflict(reload: false)
        try document.save()
        #expect(try String(contentsOf: url, encoding: .utf8) == "keep me\n")
        try? FileManager.default.removeItem(at: url)
    }

    @Test func gitInternalsAreFiltered() {
        #expect(FolderWatcher.isRelevant("/r/Sources/A.swift"))
        #expect(FolderWatcher.isRelevant("/r/.git/index"))
        #expect(FolderWatcher.isRelevant("/r/.git/HEAD"))
        #expect(FolderWatcher.isRelevant("/r/.git/refs/heads/main"))
        #expect(!FolderWatcher.isRelevant("/r/.git/objects/ab/cdef"))
        #expect(!FolderWatcher.isRelevant("/r/.git/index.lock"))
    }

    /// End to end through FSEvents: a file rewritten outside Forge reaches its open, clean buffer.
    @Test func theWatcherReloadsAnOpenFile() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("forge-watch-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "before\n".write(to: folder.appending(path: "A.swift"), atomically: true, encoding: .utf8)
        let model = ForgeModel(store: ForgeStore(documents: MemoryDocs()))
        await model.start(launch: folder.path)
        model.open(file: "A.swift", pinned: true)
        try await Task.sleep(for: .milliseconds(300))
        try touch(folder.appending(path: "A.swift"), Data("after\n".utf8))
        for _ in 0..<40 where model.documents["A.swift"]?.storage.string != "after\n" {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(model.documents["A.swift"]?.storage.string == "after\n")
    }
}
