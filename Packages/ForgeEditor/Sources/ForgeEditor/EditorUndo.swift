import AppKit
import ObjectiveC
@preconcurrency internal import CodeEditTextView

/// One undo history per buffer, kept on the buffer itself, so it outlives the editor view (E1D5 FD61).
/// Forge mounts only the active tab's editor and rebuilds it on a reload, and CodeEdit makes a fresh
/// `CEUndoManager` per view unless it is handed one: ⌘Z after a tab switch or an outside reload did nothing.
@MainActor
public enum EditorUndo {
    nonisolated(unsafe) private static var key: UInt8 = 0

    static func manager(for storage: NSTextStorage) -> CEUndoManager {
        if let manager = objc_getAssociatedObject(storage, &key) as? CEUndoManager { return manager }
        let manager = CEUndoManager()
        objc_setAssociatedObject(storage, &key, manager, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return manager
    }

    /// Replaces the whole buffer behind the editor's back (an outside reload, a search-and-replace) as one
    /// undoable step, so ⌘Z goes back to the old text and the history before it still applies.
    public static func replace(_ storage: NSTextStorage, with text: String) {
        guard text != storage.string else { return }
        // The manager reads the inverse from its text view's storage, and no editor may be mounted (a background
        // tab): a throwaway view over a copy records it. The next editor to mount re-links the manager.
        // ponytail: copies the buffer once per reload; record through the live view if that ever shows up.
        let recorder = TextView(string: storage.string, wrapLines: false)
        let manager = manager(for: storage)
        recorder.setUndoManager(manager)
        manager.beginUndoGrouping()
        recorder.replaceCharacters(in: recorder.documentRange, with: text, skipUpdateSelection: true)
        manager.endUndoGrouping()
        storage.setAttributedString(NSAttributedString(string: text))
    }
}
