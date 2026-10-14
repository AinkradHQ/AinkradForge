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
            let root = root
            files = await Task.detached { Self.existing(listed.split(separator: "\0").map(String.init), in: root) }.value
            // `git status` paths are repo-relative; the tree is relative to this folder, which may be a subfolder.
            let prefix = (try? await git.run(["rev-parse", "--show-prefix"]))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            marks = GitParse.relative(GitParse.status((try? await git.run(["--no-optional-locks", "status", "--porcelain=v1", "-z", "--untracked-files=all"])) ?? ""), to: prefix)
            // A repository with no commit yet (just initialised) has no HEAD to resolve, but its branch has a name.
            var head = try? await git.run(["rev-parse", "--abbrev-ref", "HEAD"])
            if head == nil { head = try? await git.run(["symbolic-ref", "--short", "HEAD"]) }
            branch = head?.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// A folder that is not a repo: every non-hidden file, skipping package contents. The root may itself be a
    /// link (E1D5 FD65), and links inside it are followed (FD66).
    /// ponytail: capped at 50k files; a smarter ignore list (node_modules, .build) when a non-git folder needs it.
    nonisolated static func listFolder(_ root: URL) -> [String] {
        var files: [String] = []
        walk(root, prefix: "", ancestors: [], into: &files)
        return files
    }

    /// What git listed that exists — a file deleted in the working tree is still "cached". Git lists a link to a
    /// folder as one entry: its files are listed under it instead, never the link as a file (E1D5 FD66).
    nonisolated static func existing(_ listed: [String], in root: URL) -> [String] {
        var files: [String] = []
        for path in listed {
            let url = root.appending(path: path)
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isFolder) else { continue }
            guard isFolder.boolValue, (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true else {
                files.append(path)
                continue
            }
            // The real folders from the root down to the link: a link to one of them is a loop (`src/loop → ..`).
            let parts = path.split(separator: "/").dropLast()
            let parents = [root] + parts.indices.map { root.appending(path: parts[...$0].joined(separator: "/")) }
            walk(url, prefix: path + "/", ancestors: Set(parents.map { $0.resolvingSymlinksInPath().path }), into: &files)
        }
        return files
    }

    /// Lists the non-hidden files under `folder` as `prefix` + their path in it, following links: a link to a file
    /// is a file, a link to a folder is walked — unless it leads back to a folder above it (`ancestors`, real paths).
    nonisolated private static func walk(_ folder: URL, prefix: String, ancestors: Set<String>, into files: inout [String]) {
        let real = folder.resolvingSymlinksInPath()
        guard files.count < 50_000, !ancestors.contains(real.path) else { return }
        let ancestors = ancestors.union([real.path])
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey]
        guard let children = try? FileManager.default.contentsOfDirectory(at: real, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)
        else { return }
        for child in children where files.count < 50_000 {
            guard var values = try? child.resourceValues(forKeys: Set(keys)) else { continue }
            // A link's own values describe the link; its target's say what it is (none: a dangling link).
            if values.isSymbolicLink == true {
                guard let target = try? child.resolvingSymlinksInPath().resourceValues(forKeys: Set(keys)) else { continue }
                values = target
            }
            let path = prefix + child.lastPathComponent
            if values.isRegularFile == true {
                files.append(path)
            } else if values.isDirectory == true, values.isPackage != true {
                walk(child, prefix: path + "/", ancestors: ancestors, into: &files)
            }
        }
    }
}
