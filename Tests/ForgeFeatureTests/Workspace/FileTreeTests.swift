import Testing

@testable import ForgeFeature

@Suite("File tree")
struct FileTreeTests {
    @Test func foldersFirstThenFilesInFinderOrder() {
        let tree = FileTree.build(["b.txt", "Sources/App.swift", "a10.txt", "a2.txt", "Docs/x.md"])
        #expect(tree.map(\.name) == ["Docs", "Sources", "a2.txt", "a10.txt", "b.txt"])
        #expect(tree[1].children.map(\.path) == ["Sources/App.swift"])
    }

    @Test func onlyExpandedFoldersShowTheirChildren() {
        let tree = FileTree.build(["Sources/Feature/A.swift", "Sources/B.swift", "README.md"])
        let collapsed = FileTree.visibleRows(tree, expanded: [])
        #expect(collapsed.map(\.node.path) == ["Sources", "README.md"])
        let open = FileTree.visibleRows(tree, expanded: ["Sources", "Sources/Feature"])
        #expect(open.map(\.node.path) == ["Sources", "Sources/Feature", "Sources/Feature/A.swift", "Sources/B.swift", "README.md"])
        #expect(open.map(\.depth) == [0, 1, 2, 1, 0])
    }

    @Test func foldersCarryTheirFilesMarksAndModifiedWins() {
        let marks = FileTree.folderMarks(["Sources/A/new.swift": .added, "Sources/B/x.swift": .modified, "Docs/u.md": .untracked])
        #expect(marks["Sources"] == .modified)
        #expect(marks["Sources/A"] == .added)
        #expect(marks["Docs"] == .untracked)
    }

    @Test func aFolderOfNewFilesWithOneDeletionShowsTheNewFiles() {
        let marks = FileTree.folderMarks(["Store/Old.swift": .deleted, "Store/New.swift": .untracked])
        #expect(marks["Store"] == .untracked)
    }
}
