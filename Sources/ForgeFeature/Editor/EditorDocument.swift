import AppKit
import ForgeEditor
import Foundation
import Observation

/// One open file. The editor edits `storage` in place, so a large file is never copied per keystroke.
@MainActor
@Observable
final class EditorDocument {
    enum State: Equatable {
        case loading
        case ready
        /// Not text Forge can edit (binary, or not UTF-8).
        case unreadable(String)
    }

    /// Follows a rename or move (`moved(to:)`), so saving never writes to the old path.
    private(set) var url: URL
    let language: EditorLanguage
    @ObservationIgnored let storage = NSTextStorage()
    private(set) var state: State = .loading
    private(set) var isDirty = false
    /// 1-based, for the status bar.
    var cursor = (line: 1, column: 1)

    init(url: URL) {
        self.url = url
        self.language = EditorLanguage.detect(url: url)
    }

    func load() async {
        let url = url
        let result: Result<String, Error> = await Task.detached {
            Result { try String(contentsOf: url, encoding: .utf8) }
        }.value
        switch result {
        case .success(let text):
            storage.setAttributedString(NSAttributedString(string: text))
            state = .ready
        case .failure:
            state = .unreadable("This file is not UTF-8 text.")
        }
    }

    func moved(to url: URL) { self.url = url }

    /// Called by the editor on every change.
    func didEdit() { isDirty = true }

    /// ponytail: UTF-8 only, atomic write; encodings and line-ending preservation come with E3.
    func save() throws {
        guard state == .ready else { return }
        try storage.string.write(to: url, atomically: true, encoding: .utf8)
        isDirty = false
    }
}
