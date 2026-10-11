import Testing

@testable import ForgeFeature

@Suite("Git output")
struct GitParseTests {
    @Test func porcelainStatusMarks() {
        let output = " M Sources/A.swift\0A  Sources/New.swift\0?? notes.md\0 D gone.swift\0R  to.swift\0from.swift\0"
        let marks = GitParse.status(output)
        #expect(marks == [
            "Sources/A.swift": .modified, "Sources/New.swift": .added, "notes.md": .untracked,
            "gone.swift": .deleted, "to.swift": .modified,
        ])
    }

    @Test func worktreeList() {
        let output = """
            worktree /repo
            HEAD 1111111111111111111111111111111111111111
            branch refs/heads/development

            worktree /repo/.build/fix
            HEAD abcdef0123456789abcdef0123456789abcdef01
            detached

            """
        let trees = GitParse.worktrees(output)
        #expect(trees.map(\.path) == ["/repo", "/repo/.build/fix"])
        #expect(trees.map(\.branch) == ["development", "abcdef0"])
    }

    @Test func subfolderMarksAreRelativeToIt() {
        let marks = GitParse.relative(["Sources/A.swift": .modified, "README.md": .modified], to: "Sources/")
        #expect(marks == ["A.swift": .modified])
    }
}
