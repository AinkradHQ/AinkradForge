import AppKit
import ForgeEditor
import Foundation
import Observation

/// One open file. The editor edits `storage` in place, so a large file is never copied per keystroke.
/// It remembers how the file is stored (encoding, BOM, line endings) and writes it back the same way.
/// The buffer itself always uses LF: CodeEditTextView draws a CRLF break as an extra blank row, so CR / CRLF
/// files are normalised on load and their own line ending is written back on save.
@MainActor
@Observable
final class EditorDocument {
    enum State: Equatable {
        case loading
        case ready
        /// Not text Forge can edit (binary).
        case unreadable(String)
    }

    /// The file changed on disk while this buffer had unsaved edits (or vanished): the window asks.
    enum Conflict: Equatable {
        case modified
        case deleted
    }

    /// Follows a rename or move (`moved(to:)`), so saving never writes to the old path.
    private(set) var url: URL
    let language: EditorLanguage
    @ObservationIgnored let storage = NSTextStorage()
    private(set) var state: State = .loading
    private(set) var isDirty = false
    private(set) var format = TextFormat()
    private(set) var conflict: Conflict?
    /// Bumped whenever the whole buffer is replaced behind the editor's back (a reload).
    /// The editor is rebuilt on a new revision: CodeEdit's syntax tree only follows edits made through it.
    private(set) var revision = 0
    /// 1-based, for the status bar.
    var cursor = (line: 1, column: 1)
    /// Told after every successful save (the language server hears about it).
    @ObservationIgnored var onSaved: (EditorDocument) -> Void = { _ in }
    /// What the file looked like when last read or written by Forge, to tell outside changes from our own saves.
    @ObservationIgnored private var diskStamp: DiskStamp?

    struct DiskStamp: Equatable, Sendable {
        let modified: Date
        let size: Int
    }

    init(url: URL) {
        self.url = url
        self.language = EditorLanguage.detect(url: url)
    }

    func load() async {
        let url = url
        let read: (TextFile.Decoded, DiskStamp?)? = await Task.detached {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return (TextFile.decode(data), Self.stamp(url))
        }.value
        guard let (decoded, stamp) = read else {
            state = .unreadable("The file could not be read.")
            return
        }
        switch decoded {
        case .text(let text, let format):
            if state == .ready { revision += 1 }
            let buffer = format.lineEnding == .lf && !text.unicodeScalars.contains("\r") ? text : TextFile.convert(text, to: .lf)
            storage.setAttributedString(NSAttributedString(string: buffer))
            self.format = format
            diskStamp = stamp
            isDirty = false
            conflict = nil
            state = .ready
        case .binary:
            state = .unreadable("This looks like a binary file.")
        }
    }

    func moved(to url: URL) { self.url = url }

    /// Replaces the whole buffer (a search-and-replace): unsaved, and the editor rebuilt so its syntax tree
    /// re-parses. Saving writes it in the file's own encoding and line endings.
    func replaceText(_ text: String) {
        guard state == .ready, text != storage.string else { return }
        storage.setAttributedString(NSAttributedString(string: text))
        revision += 1
        isDirty = true
    }

    /// Called by the editor on every change.
    func didEdit() { isDirty = true }

    /// Writes the buffer back in its own encoding and line endings, atomically.
    func save() throws {
        guard state == .ready else { return }
        let text = format.lineEnding == .lf ? storage.string : TextFile.convert(storage.string, to: format.lineEnding)
        try TextFile.encode(text, as: format).write(to: url, options: .atomic)
        diskStamp = Self.stamp(url)
        isDirty = false
        conflict = nil
        onSaved(self)
    }

    /// Something on disk changed near this file: reload a clean buffer, or flag a conflict on a dirty one.
    /// Our own saves are recognised by the stamp and ignored.
    func checkDisk() async {
        guard state == .ready else { return }
        let stamp = Self.stamp(url)
        guard stamp != diskStamp else { return }
        if stamp == nil {
            // Gone (deleted, or moved by something else): keep the text; the user decides.
            conflict = .deleted
        } else if isDirty {
            conflict = .modified
        } else {
            await load()
        }
    }

    /// The answer to a conflict: take the disk version, or keep the buffer (the next save overwrites the file).
    func resolveConflict(reload: Bool) async {
        if reload, conflict == .modified {
            await load()
        } else {
            conflict = nil
            diskStamp = Self.stamp(url)
            isDirty = true
        }
    }

    /// The line ending the next save writes (the buffer is always LF); dirty so the change is saved.
    func convertLineEndings(to ending: TextFormat.LineEnding) {
        guard ending != format.lineEnding else { return }
        format.lineEnding = ending
        isDirty = true
    }

    /// Changes the encoding the next save uses (e.g. a Windows 1252 file to UTF-8).
    func setEncoding(_ encoding: TextFormat.Encoding) {
        guard encoding != format.encoding else { return }
        format.encoding = encoding
        isDirty = true
    }

    nonisolated static func stamp(_ url: URL) -> DiskStamp? {
        // A URL caches its resource values; without this the second look reads the first one's answer.
        var url = url
        url.removeAllCachedResourceValues()
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
            let modified = values.contentModificationDate
        else { return nil }
        return DiskStamp(modified: modified, size: values.fileSize ?? 0)
    }
}
