import Foundation

/// One row of the file tree: a folder or a file, addressed by its workspace-relative path.
struct FileNode: Identifiable, Equatable, Sendable {
    /// Workspace-relative path, `/`-separated; also the id.
    let path: String
    let name: String
    let isDirectory: Bool
    var children: [FileNode]

    var id: String { path }
}

/// Builds the tree from a flat list of workspace-relative file paths (what `git ls-files` prints).
/// Folders come first, then files, each sorted the way Finder sorts names. Pure, so it is tested directly.
enum FileTree {
    static func build(_ paths: [String]) -> [FileNode] {
        final class Folder {
            var folders: [String: Folder] = [:]
            var files: Set<String> = []
        }
        let root = Folder()
        for path in paths {
            let parts = path.split(separator: "/").map(String.init)
            guard let file = parts.last else { continue }
            var folder = root
            for part in parts.dropLast() {
                if let next = folder.folders[part] {
                    folder = next
                } else {
                    let next = Folder()
                    folder.folders[part] = next
                    folder = next
                }
            }
            folder.files.insert(file)
        }
        func nodes(_ folder: Folder, prefix: String) -> [FileNode] {
            let order: (String, String) -> Bool = { $0.localizedStandardCompare($1) == .orderedAscending }
            let dirs = folder.folders.sorted { order($0.key, $1.key) }.map { name, child in
                FileNode(path: prefix + name, name: name, isDirectory: true, children: nodes(child, prefix: prefix + name + "/"))
            }
            let files = folder.files.sorted(by: order).map {
                FileNode(path: prefix + $0, name: $0, isDirectory: false, children: [])
            }
            return dirs + files
        }
        return nodes(root, prefix: "")
    }

    /// The rows a tree shows with `expanded` folders open, depth-first, each with its indent level.
    static func visibleRows(_ nodes: [FileNode], expanded: Set<String>, depth: Int = 0) -> [(node: FileNode, depth: Int)] {
        nodes.flatMap { node -> [(node: FileNode, depth: Int)] in
            guard node.isDirectory, expanded.contains(node.path) else { return [(node, depth)] }
            return [(node, depth)] + visibleRows(node.children, expanded: expanded, depth: depth + 1)
        }
    }

    /// Every folder that contains a marked file gets the strongest mark inside it — modified, then added,
    /// untracked, deleted — so a collapsed folder still shows that something changed, and a folder of new
    /// files with one deletion does not read as red.
    static func folderMarks(_ marks: [String: GitMark]) -> [String: GitMark] {
        let rank: [GitMark: Int] = [.modified: 3, .added: 2, .untracked: 1, .deleted: 0]
        var folders: [String: GitMark] = [:]
        for (path, mark) in marks {
            var parts = path.split(separator: "/").dropLast()
            while !parts.isEmpty {
                let folder = parts.joined(separator: "/")
                if (rank[folders[folder] ?? .deleted] ?? 0) <= (rank[mark] ?? 0) || folders[folder] == nil { folders[folder] = mark }
                parts = parts.dropLast()
            }
        }
        return folders
    }
}
