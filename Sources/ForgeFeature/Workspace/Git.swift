import Foundation

/// Runs `git` in a working tree. `/usr/bin/git` is always present on macOS, so no login-shell PATH is needed.
struct Git: Sendable {
    let directory: URL

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// stdout on exit 0; otherwise throws with stderr as the message.
    func run(_ arguments: [String]) async throws -> String {
        let directory = directory
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let out = Pipe()
            let err = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = directory
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice
            try process.run()
            // Read before waiting: a full pipe would block the child forever.
            let output = out.fileHandleForReading.readDataToEndOfFile()
            let errors = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw Failure(message: String(decoding: errors, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return String(decoding: output, as: UTF8.self)
        }.value
    }
}

/// A file's state in `git status`, as the tree shows it.
enum GitMark: String, Codable, Sendable {
    case modified = "M", added = "A", untracked = "U", deleted = "D"
}

/// Parsers for git's machine-readable output. Pure, so they are tested without a repository.
enum GitParse {
    /// `git status --porcelain=v1 -z` → repo-relative path → mark. Renames report the new path.
    static func status(_ output: String) -> [String: GitMark] {
        var marks: [String: GitMark] = [:]
        var entries = output.split(separator: "\0", omittingEmptySubsequences: true).makeIterator()
        while let entry = entries.next() {
            guard entry.count > 3 else { continue }
            let code = entry.prefix(2)
            let path = String(entry.dropFirst(3))
            if code.contains("R") || code.contains("C") { _ = entries.next() }  // the old path follows a rename
            marks[path] =
                switch code {
                case "??": .untracked
                case _ where code.contains("D"): .deleted
                case _ where code.contains("A"): .added
                default: .modified
                }
        }
        return marks
    }

    /// Repo-relative marks → marks relative to the subfolder `prefix` (`git rev-parse --show-prefix`, e.g.
    /// `Sources/`); files outside it are dropped.
    static func relative(_ marks: [String: GitMark], to prefix: String) -> [String: GitMark] {
        guard !prefix.isEmpty else { return marks }
        return Dictionary(uniqueKeysWithValues: marks.compactMap { path, mark in
            path.hasPrefix(prefix) ? (String(path.dropFirst(prefix.count)), mark) : nil
        })
    }

    /// `git worktree list --porcelain` → (path, branch) per worktree; detached ones use their short HEAD.
    static func worktrees(_ output: String) -> [(path: String, branch: String)] {
        output.components(separatedBy: "\n\n").compactMap { block in
            var path: String?
            var branch: String?
            var head: String?
            for line in block.split(separator: "\n") {
                if line.hasPrefix("worktree ") { path = String(line.dropFirst("worktree ".count)) }
                if line.hasPrefix("branch ") { branch = String(line.dropFirst("branch refs/heads/".count)) }
                if line.hasPrefix("HEAD ") { head = String(line.dropFirst("HEAD ".count).prefix(7)) }
            }
            guard let path else { return nil }
            return (path, branch ?? head ?? "detached")
        }
    }
}
