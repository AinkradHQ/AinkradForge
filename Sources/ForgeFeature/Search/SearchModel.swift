import Foundation
import Observation

/// The sidebar's Search tab: the query, its toggles and globs, and the results as they stream in.
@MainActor
@Observable
final class SearchModel {
    struct FileResult: Identifiable, Equatable {
        let path: String
        var matches: [LineMatch]
        var id: String { path }
    }

    enum Status: Equatable {
        case idle
        case searching
        case done(lines: Int, files: Int, milliseconds: Int, capped: Bool)
        case failed(String)
    }

    /// Lines, across all files, after which a search stops: a broad query stays fast.
    static let cap = 2_000

    var query = SearchQuery()
    var replacement = ""
    var isReplaceOpen = false
    var preserveCase = false
    var include = ""
    var exclude = ""
    private(set) var results: [FileResult] = []
    private(set) var status: Status = .idle
    /// Files whose rows are folded.
    var collapsed: Set<String> = []
    /// The file whose replace preview is open in the editor area.
    var previewPath: String?
    /// Per file, the preview hunks the user unticked: Replace leaves those lines as they are.
    var rejected: [String: Set<Int>] = [:]
    /// Replace All was asked for; the window confirms first.
    var confirmingReplaceAll = false
    @ObservationIgnored private var running: Task<Void, Never>?

    var lineCount: Int { results.reduce(0) { $0 + $1.matches.count } }

    /// Runs the search after a short pause (typing restarts it). `files` is the workspace's (gitignore-aware)
    /// file list; `buffers` holds the text of open files with unsaved edits, searched instead of the disk.
    func schedule(root: URL, files: [String], buffers: [String: String], delay: Duration = .milliseconds(250)) {
        running?.cancel()
        let regex: NSRegularExpression
        do {
            guard let compiled = try query.compile() else {
                results = []
                status = .idle
                return
            }
            regex = compiled
        } catch {
            results = []
            status = .failed(error.localizedDescription)
            return
        }
        let include = GlobSet(include)
        let exclude = GlobSet(exclude)
        let candidates = files.filter { (include.isEmpty || include.matches($0)) && !exclude.matches($0) }
        // At once, not after the pause: the old "done" summary must not stand for a search not yet run.
        status = .searching
        running = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await search(regex: regex, root: root, files: candidates, buffers: buffers)
        }
    }

    /// Forgets the results (a new workspace, or an emptied query).
    func clear() {
        running?.cancel()
        results = []
        status = .idle
    }

    private func search(regex: NSRegularExpression, root: URL, files: [String], buffers: [String: String]) async {
        let started = ContinuousClock.now
        results = []
        status = .searching
        var found = 0
        // Batches of files scanned off the main actor; each batch's hits are appended as it finishes.
        for batch in stride(from: 0, to: files.count, by: 64).map({ Array(files[$0..<min($0 + 64, files.count)]) }) {
            guard !Task.isCancelled else { return }
            let hits = await Task.detached(priority: .userInitiated) {
                batch.compactMap { path -> FileResult? in
                    guard let text = buffers[path] ?? Self.readText(root.appending(path: path)) else { return nil }
                    let matches = TextSearch.matches(in: text, regex: regex)
                    return matches.isEmpty ? nil : FileResult(path: path, matches: matches)
                }
            }.value
            guard !Task.isCancelled else { return }
            for hit in hits {
                let room = Self.cap - found
                guard room > 0 else { break }
                let kept = FileResult(path: hit.path, matches: Array(hit.matches.prefix(room)))
                results.append(kept)
                found += kept.matches.count
            }
            if found >= Self.cap { break }
        }
        let elapsed = ContinuousClock.now - started
        status = .done(
            lines: found, files: results.count,
            milliseconds: Int(elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000),
            capped: found >= Self.cap)
    }

    /// Text of a file for searching: UTF-8 or the other encodings Forge reads; binary files are skipped.
    nonisolated static func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), data.count < 8_000_000 else { return nil }
        if case .text(let text, _) = TextFile.decode(data) { return text }
        return nil
    }
}
