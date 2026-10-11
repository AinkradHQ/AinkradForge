import Foundation

/// Something the workspace can run, found by reading it: a Makefile target, a `package.json` or
/// `composer.json` script.
struct WorkspaceTask: Identifiable, Hashable, Sendable {
    /// e.g. "Makefile", "package.json · apps/site".
    let group: String
    let name: String
    /// What it runs, as shown ("make build", "next dev").
    let shows: String
    /// The shell command that runs it, from the workspace folder.
    let command: String

    var id: String { group + "\u{0}" + name }
}

/// Reads tasks out of the workspace's files. Pure (given file contents), so each format is tested directly.
enum TaskCatalog {
    /// Every task under `root`, from the (gitignore-aware) file list: Makefiles first, then each package's
    /// scripts, then Composer's — each group in the order its folder sorts.
    static func detect(root: URL, files: [String]) -> [WorkspaceTask] {
        let read = { (path: String) in try? String(contentsOf: root.appending(path: path), encoding: .utf8) }
        let names = Set(files)
        var make: [WorkspaceTask] = []
        var node: [WorkspaceTask] = []
        var composer: [WorkspaceTask] = []
        for path in files.sorted() where !path.contains("node_modules/") && !path.contains("vendor/") {
            let name = (path as NSString).lastPathComponent
            let folder = (path as NSString).deletingLastPathComponent
            guard ["Makefile", "makefile", "GNUmakefile", "package.json", "composer.json"].contains(name), let text = read(path)
            else { continue }
            let at = folder.isEmpty ? "" : " · \(folder)"
            let cd = folder.isEmpty ? "" : "cd \(quoted(folder)) && "
            switch name {
            case "package.json":
                let manager = packageManager(folder: folder, files: names)
                node += scripts(json: text).map {
                    WorkspaceTask(group: "package.json\(at)", name: $0.name, shows: $0.body, command: "\(cd)\(manager) run \(quoted($0.name))")
                }
            case "composer.json":
                composer += scripts(json: text).map {
                    WorkspaceTask(group: "composer.json\(at)", name: $0.name, shows: $0.body, command: "\(cd)composer run-script \(quoted($0.name))")
                }
            default:
                make += makeTargets(text).map {
                    WorkspaceTask(group: "Makefile\(at)", name: $0, shows: "make \($0)", command: "\(cd)make \(quoted($0))")
                }
            }
        }
        return make + node + composer
    }

    /// Targets a person would run: `name:` at a line's start — not `.PHONY`-style specials, pattern rules
    /// (`%.o:`) or variable assignments (`X := …`).
    static func makeTargets(_ text: String) -> [String] {
        var seen: [String] = []
        let pattern = /^([A-Za-z0-9_][A-Za-z0-9_.\/-]*)\s*:(?![=:])/
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let match = line.prefixMatch(of: pattern) else { continue }
            let target = String(match.1)
            if !seen.contains(target) { seen.append(target) }
        }
        return seen
    }

    /// A JSON file's `scripts`, in the file's own order, each with what it runs (an array's first entry).
    static func scripts(json text: String) -> [(name: String, body: String)] {
        guard let data = text.data(using: .utf8),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let scripts = object["scripts"] as? [String: Any]
        else { return [] }
        func body(_ value: Any) -> String {
            if let string = value as? String { return string }
            if let list = value as? [Any], let first = list.first { return body(first) + (list.count > 1 ? " …" : "") }
            return ""
        }
        // JSONSerialization forgets key order; the order they are written in is the one people know.
        let order = scripts.keys.sorted { (text.range(of: "\"\($0)\"")?.lowerBound ?? text.endIndex) < (text.range(of: "\"\($1)\"")?.lowerBound ?? text.endIndex) }
        return order.map { ($0, body(scripts[$0] ?? "")) }
    }

    /// The package manager a folder uses, by its lockfile there or at the workspace root.
    static func packageManager(folder: String, files: Set<String>) -> String {
        for dir in [folder, ""] {
            let at = { (name: String) in files.contains(dir.isEmpty ? name : "\(dir)/\(name)") }
            if at("pnpm-lock.yaml") { return "pnpm" }
            if at("yarn.lock") { return "yarn" }
            if at("bun.lockb") || at("bun.lock") { return "bun" }
            if at("package-lock.json") { return "npm" }
        }
        return "npm"
    }

    /// Single-quoted for the shell.
    static func quoted(_ text: String) -> String {
        text.allSatisfy { $0.isLetter || $0.isNumber || "_-./:".contains($0) } ? text : "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
