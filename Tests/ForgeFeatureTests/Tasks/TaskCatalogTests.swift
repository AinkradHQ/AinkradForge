import Foundation
import Testing

@testable import ForgeFeature

@Suite("Task catalog")
struct TaskCatalogTests {
    @Test func makeTargetsSkipSpecialsPatternsAndAssignments() {
        let makefile = """
            .PHONY: build test
            CC := clang
            VERSION = 1
            build: generate
            \t$(CC) -o app
            test:
            generate::
            %.o: %.c
            release/dmg: build
            build: more
            """
        #expect(TaskCatalog.makeTargets(makefile) == ["build", "test", "release/dmg"])
    }

    @Test func scriptsKeepTheirWrittenOrder() {
        let json = #"{"name": "site", "scripts": {"dev": "next dev", "build": "next build", "lint": ["eslint .", "tsc"]}}"#
        let scripts = TaskCatalog.scripts(json: json)
        #expect(scripts.map(\.name) == ["dev", "build", "lint"])
        #expect(scripts.map(\.body) == ["next dev", "next build", "eslint . …"])
        #expect(TaskCatalog.scripts(json: "{}").isEmpty)
    }

    @Test func detectsEachKindWithItsFolderAndPackageManager() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("forge-tasks-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let files = [
            "Makefile": "build:\n\tswift build\n",
            "apps/site/package.json": #"{"scripts": {"dev": "next dev"}}"#,
            "pnpm-lock.yaml": "",
            "composer.json": #"{"scripts": {"test": "phpunit"}}"#,
            "node_modules/x/package.json": #"{"scripts": {"no": "x"}}"#,
        ]
        for (path, text) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let tasks = TaskCatalog.detect(root: root, files: Array(files.keys))
        #expect(tasks.map(\.group) == ["Makefile", "package.json · apps/site", "composer.json"])
        #expect(tasks.map(\.command) == ["make build", "cd apps/site && pnpm run dev", "composer run-script test"])
        #expect(tasks.map(\.shows) == ["make build", "next dev", "phpunit"])
        #expect(TaskCatalog.quoted("it's") == "'it'\\''s'")
    }
}
