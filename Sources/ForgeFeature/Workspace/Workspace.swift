import Foundation
import Observation

/// An opened folder — usually a git repo or worktree — and what the sidebar and status bar show about it.
@MainActor
@Observable
final class Workspace {
    let root: URL
    var name: String { root.lastPathComponent }

    private(set) var tree: [FileNode] = []
    /// Every listed file, workspace-relative; the quick-open index.
    private(set) var files: [String] = []
    private(set) var marks: [String: GitMark] = [:]
    private(set) var folderMarks: [String: GitMark] = [:]
    private(set) var branch: String?
    private(set) var worktrees: [(path: String, branch: String)] = []
    private(set) var isLoading = false

    private var git: Git { Git(directory: root) }

    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    func url(for path: String) -> URL { root.appending(path: path) }

    func relativePath(of url: URL) -> String? {
        let base = root.path(percentEncoded: false)
        let full = url.standardizedFileURL.path(percentEncoded: false)
        let prefix = base.hasSuffix("/") ? base : base + "/"
        return full.hasPrefix(prefix) ? String(full.dropFirst(prefix.count)) : nil
    }

    /// Re-reads the file list and git state. Safe to call often; the work runs off the main actor.
    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        let isRepo = (try? await git.run(["rev-parse", "--is-inside-work-tree"]))?.hasPrefix("true") == true
        if isRepo {
            let listed = (try? await git.run(["ls-files", "-co", "--exclude-standard", "-z"])) ?? ""
            // A file deleted in the working tree is still "cached"; only list what exists.
            let root = root
            files = await Task.detached {
                listed.split(separator: "\0").map(String.init)
                    .filter { FileManager.default.fileExists(atPath: root.appending(path: $0).path(percentEncoded: false)) }
            }.value
            // `git status` paths are repo-relative; the tree is relative to this folder, which may be a subfolder.
            let prefix = (try? await git.run(["rev-parse", "--show-prefix"]))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            marks = GitParse.relative(GitParse.status((try? await git.run(["--no-optional-locks", "status", "--porcelain=v1", "-z", "--untracked-files=all"])) ?? ""), to: prefix)
            branch = (try? await git.run(["rev-parse", "--abbrev-ref", "HEAD"]))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            worktrees = GitParse.worktrees((try? await git.run(["worktree", "list", "--porcelain"])) ?? "")
        } else {
            let root = root
            files = await Task.detached { Self.listFolder(root) }.value
            marks = [:]
            branch = nil
            worktrees = []
        }
        folderMarks = FileTree.folderMarks(marks)
        tree = FileTree.build(files)
    }

    /// Files changed against HEAD (the Changes tab), sorted by path.
    var changes: [(path: String, mark: GitMark)] {
        marks.map { ($0.key, $0.value) }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// A folder that is not a repo: every non-hidden file, skipping package contents.
    /// ponytail: capped at 50k files; a smarter ignore list (node_modules, .build) when a non-git folder needs it.
    nonisolated private static func listFolder(_ root: URL) -> [String] {
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        let prefix = root.path(percentEncoded: false).count + (root.path(percentEncoded: false).hasSuffix("/") ? 0 : 1)
        var files: [String] = []
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            files.append(String(url.standardizedFileURL.path(percentEncoded: false).dropFirst(prefix)))
            if files.count >= 50_000 { break }
        }
        return files
    }
}
