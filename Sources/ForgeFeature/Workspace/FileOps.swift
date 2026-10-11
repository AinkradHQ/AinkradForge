import Foundation

/// File operations on a workspace, by workspace-relative path. Each returns the new relative path, and throws
/// a message fit for a toast. Nothing here is ever a hard delete: removal goes to the Trash.
enum FileOps {
    struct Failure: LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    /// A name for a new or renamed item: not empty, no `/`, not `.` or `..`.
    static func validate(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure(message: "A name can't be empty.") }
        guard !trimmed.contains("/"), trimmed != ".", trimmed != ".." else {
            throw Failure(message: "“\(trimmed)” isn't a valid name.")
        }
        return trimmed
    }

    static func createFile(named name: String, in folder: String, root: URL) throws -> String {
        let path = join(folder, try validate(name))
        let url = root.appending(path: path)
        try refuseExisting(url, path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: Data()) else {
            throw Failure(message: "Could not create \(path).")
        }
        return path
    }

    static func createFolder(named name: String, in folder: String, root: URL) throws -> String {
        let path = join(folder, try validate(name))
        let url = root.appending(path: path)
        try refuseExisting(url, path)
        try wrap { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        return path
    }

    static func rename(_ path: String, to name: String, root: URL) throws -> String {
        let new = join(parent(of: path), try validate(name))
        guard new != path else { return path }
        try move(path, to: new, root: root)
        return new
    }

    /// Moves `path` into `folder` ("" = the workspace root).
    static func move(_ path: String, into folder: String, root: URL) throws -> String {
        let new = join(folder, (path as NSString).lastPathComponent)
        guard new != path else { return path }
        guard !(folder + "/").hasPrefix(path + "/") else { throw Failure(message: "A folder can't move into itself.") }
        try move(path, to: new, root: root)
        return new
    }

    /// "name copy.ext", then "name copy 2.ext", … beside the original.
    static func duplicate(_ path: String, root: URL) throws -> String {
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var attempt = 1
        var new: String
        repeat {
            let suffix = attempt == 1 ? " copy" : " copy \(attempt)"
            new = join(parent(of: path), stem + suffix + (ext.isEmpty ? "" : "." + ext))
            attempt += 1
        } while FileManager.default.fileExists(atPath: root.appending(path: new).path(percentEncoded: false))
        try wrap { try FileManager.default.copyItem(at: root.appending(path: path), to: root.appending(path: new)) }
        return new
    }

    /// Copies a file dropped from Finder into `folder`, keeping its name (a clash gets " copy").
    static func copyIn(_ url: URL, into folder: String, root: URL) throws -> String {
        var new = join(folder, url.lastPathComponent)
        if FileManager.default.fileExists(atPath: root.appending(path: new).path(percentEncoded: false)) {
            let ext = url.pathExtension
            let stem = url.deletingPathExtension().lastPathComponent
            new = join(folder, stem + " copy" + (ext.isEmpty ? "" : "." + ext))
        }
        let target = root.appending(path: new)
        try refuseExisting(target, new)
        try wrap { try FileManager.default.copyItem(at: url, to: target) }
        return new
    }

    /// To the Trash — recoverable from Finder, never a hard delete.
    static func trash(_ path: String, root: URL) throws {
        try wrap { try FileManager.default.trashItem(at: root.appending(path: path), resultingItemURL: nil) }
    }

    /// `path` after `old` (a file or folder) became `new`; nil when `path` is not at or under `old`.
    static func remap(_ path: String, from old: String, to new: String) -> String? {
        if path == old { return new }
        return path.hasPrefix(old + "/") ? new + path.dropFirst(old.count) : nil
    }

    static func parent(of path: String) -> String { (path as NSString).deletingLastPathComponent }

    private static func join(_ folder: String, _ name: String) -> String { folder.isEmpty ? name : folder + "/" + name }

    private static func move(_ path: String, to new: String, root: URL) throws {
        let target = root.appending(path: new)
        try refuseExisting(target, new)
        try wrap { try FileManager.default.moveItem(at: root.appending(path: path), to: target) }
    }

    private static func refuseExisting(_ url: URL, _ path: String) throws {
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            throw Failure(message: "\(path) already exists.")
        }
    }

    private static func wrap(_ body: () throws -> Void) throws {
        do { try body() } catch let failure as Failure { throw failure } catch {
            throw Failure(message: error.localizedDescription)
        }
    }
}
