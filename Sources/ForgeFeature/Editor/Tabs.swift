import Foundation

/// The open tabs of one editor pane, by workspace-relative path. A value type with no UI, so the rules are
/// tested directly:
/// - a single click opens a **preview** tab (italic) that the next single click replaces;
/// - double-click or an edit **pins** it;
/// - closing the active tab activates its right neighbour, else its left one.
struct Tabs: Codable, Equatable, Sendable {
    private(set) var paths: [String] = []
    private(set) var active: String?
    /// The one unpinned tab, if any.
    private(set) var preview: String?

    mutating func open(_ path: String, pinned: Bool) {
        if paths.contains(path) {
            if pinned, preview == path { preview = nil }
        } else if !pinned, let old = preview, let index = paths.firstIndex(of: old) {
            paths[index] = path
            preview = path
        } else {
            let at = active.flatMap { paths.firstIndex(of: $0) }.map { $0 + 1 } ?? paths.endIndex
            paths.insert(path, at: at)
            if !pinned { preview = path }
        }
        active = path
    }

    mutating func pin(_ path: String) {
        if preview == path { preview = nil }
    }

    mutating func activate(_ path: String) {
        if paths.contains(path) { active = path }
    }

    mutating func close(_ path: String) {
        guard let index = paths.firstIndex(of: path) else { return }
        paths.remove(at: index)
        if preview == path { preview = nil }
        if active == path {
            active = paths.isEmpty ? nil : paths[min(index, paths.count - 1)]
        }
    }

    /// A file was renamed or moved on disk: its tab follows it.
    mutating func rename(_ old: String, to new: String) {
        guard let index = paths.firstIndex(of: old) else { return }
        paths[index] = new
        if active == old { active = new }
        if preview == old { preview = new }
    }
}
