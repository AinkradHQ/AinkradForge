import AinkradAppKit
import ForgeEditor
import ForgeLanguage
import Foundation

/// Git in the editor: gutter marks, the peek with Revert / Stage, blame on demand.
extension ForgeModel {
    /// The buffer of `path` changed (or loaded): recompute its marks.
    func gitChanged(_ path: String) {
        guard let workspace, let document = documents[path], document.state == .ready else { return }
        git.update(path, text: document.storage.string, git: Git(directory: workspace.root))
    }

    /// A gutter mark was clicked: peek at that change (again: close it).
    func peekChange(pane: Int, path: String, hunk: Int, rect: CGRect) {
        let next = GitPeek(pane: pane, path: path, hunk: hunk, rect: rect)
        git.peek = git.peek == next ? nil : next
    }

    /// ↑↓ in the peek: the previous / next change in the file, the editor following it.
    func stepPeek(by step: Int) {
        guard let peek = git.peek, let hunks = git.hunks[peek.path], !hunks.isEmpty else { return }
        let index = (peek.hunk + step + hunks.count) % hunks.count
        git.peek = GitPeek(pane: peek.pane, path: peek.path, hunk: index, rect: peek.rect)
        pendingLine = max(1, hunks[index].newStart)
    }

    /// Revert Change: HEAD's lines back in place of the buffer's, through the editor (undoable).
    func revertPeek() {
        guard let peek = git.peek, let hunk = git.hunks[peek.path]?[safe: peek.hunk] else { return }
        let old = hunk.lines.filter { $0.kind == .deletion }.map { $0.text + "\n" }.joined()
        let change: TextChange
        if hunk.newCount == 0 {
            // Lines removed after line `newStart`: put them back at the start of the next line.
            change = TextChange(start: (hunk.newStart, 0), end: (hunk.newStart, 0), newText: old)
        } else {
            change = TextChange(start: (hunk.newStart - 1, 0), end: (hunk.newStart - 1 + hunk.newCount, 0), newText: old)
        }
        git.peek = nil
        apply([peek.path: [change]])
    }

    /// Stage Change: just this hunk into the index. The file on disk must match the buffer (saved).
    func stagePeek() {
        guard let peek = git.peek, let workspace, let hunk = git.hunks[peek.path]?[safe: peek.hunk] else { return }
        guard documents[peek.path]?.isDirty != true else { return notice = "Save the file first: staging takes changes from disk." }
        let git = Git(directory: workspace.root)
        self.git.peek = nil
        Task {
            do {
                let full = try await git.run(["ls-files", "--full-name", "--", peek.path]).trimmingCharacters(in: .whitespacesAndNewlines)
                let top = try await git.run(["rev-parse", "--show-toplevel"]).trimmingCharacters(in: .whitespacesAndNewlines)
                _ = try await Git(directory: URL(fileURLWithPath: top)).run(
                    ["apply", "--cached", "--unidiff-zero", "-"], input: Data(GitLines.patch(path: full, hunk: hunk).utf8))
                await workspace.refresh()
            } catch {
                notice = "Could not stage the change: \(error.localizedDescription)"
            }
        }
    }

    /// Opens Git Mage (it does not take a repository or commit to show yet).
    func openGitMage() {
        git.peek = nil
        apps?.open(appID: Self.gitMageAppID, payload: nil)
    }

    static let gitMageAppID = "gitmage"

    /// ⌥⌘B: blame on the caret's line, on or off.
    func toggleBlame() {
        git.blameOn.toggle()
        git.blame = nil
        if git.blameOn { blameCaret() }
    }

    /// The caret moved (or blame came on): blame its line.
    func blameCaret() {
        guard git.blameOn, let workspace, let path = tabs.active, let document = documents[path], document.state == .ready else { return }
        git.caretMoved(path: path, line: document.cursor.line, text: document.storage.string, git: Git(directory: workspace.root))
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
