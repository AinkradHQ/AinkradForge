import AinkradAppKit
import AppKit
import ForgeEditor
import ForgeLanguage
import Foundation

/// Reviewing changes made from outside Forge: keep or undo each, step through them.
extension ForgeModel {
    /// The buffer of `path` changed in Forge (typing, or our own undo).
    func bufferChanged(_ path: String) {
        gitChanged(path)
        if let document = documents[path] { agent.edited(path, text: document.storage.string) }
    }

    /// The outside change under the caret in the active file, if any (⌘↵ / ⌘⌫ act on it).
    var agentChangeAtCaret: (path: String, hunk: Int)? {
        guard let path = tabs.active, let document = documents[path],
            let hunk = agent.hunk(path, containing: document.cursor.line)
        else { return nil }
        return (path, hunk)
    }

    func keepChange(_ path: String, hunk: Int) {
        guard let document = documents[path] else { return }
        agent.showingWas = false
        agent.keep(path, hunk: hunk, text: document.storage.string)
    }

    func undoChange(_ path: String, hunk: Int) {
        agent.showingWas = false
        guard let change = agent.undo(path, hunk: hunk) else { return }
        apply([path: [change]])
    }

    func keepAllChanges(_ path: String) {
        agent.showingWas = false
        agent.keepAll(path)
    }

    func undoAllChanges(_ path: String) {
        guard let document = documents[path], let change = agent.undoAll(path, text: document.storage.string) else { return }
        agent.showingWas = false
        apply([path: [change]])
    }

    /// ‹ ›: the previous / next change, the editor following it.
    func stepChange(_ path: String, by step: Int) {
        guard let count = agent.files[path]?.diff.hunks.count, count > 0 else { return }
        let next = ((agent.current[path] ?? 0) + step + count) % count
        agent.current[path] = next
        agent.showingWas = false
        if let line = agent.anchorLine(path, hunk: next) { pendingLine = line }
    }

    /// The wash behind written lines, and the gutter's bars and notches (tags past `agentTagBase`).
    func agentMarks(_ path: String, color: NSColor) -> (wash: [EditorMark], gutter: [EditorLineMark]) {
        guard let file = agent.files[path], let document = documents[path] else { return ([], []) }
        let index = LineIndex(document.storage.string)
        var wash: [EditorMark] = []
        var gutter: [EditorLineMark] = []
        for (number, hunk) in file.diff.hunks.enumerated() {
            let written = hunk.lines.compactMap { $0.kind == .insertion ? $0.newNumber : nil }
            if let first = written.first, let last = written.last {
                // A mark per line: one spanning lines washes only its first.
                wash += written.map { EditorMark(range: index.range(from: ($0 - 1, 0), to: ($0, 0)), color: color.withAlphaComponent(0.09), isLineWash: true) }
                gutter.append(EditorLineMark(lines: first...last, color: color, isRemoval: false, tag: Self.agentTagBase + number))
            } else if let line = agent.anchorLine(path, hunk: number) {
                gutter.append(EditorLineMark(lines: (line - 1)...(line - 1), color: color, isRemoval: true, tag: Self.agentTagBase + number))
            }
        }
        return (wash, gutter)
    }

    /// Gutter mark tags from this up are outside changes; below, git's.
    static let agentTagBase = 10_000
}
