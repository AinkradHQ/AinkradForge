import AppKit
@preconcurrency internal import CodeEditSourceEditor
@preconcurrency internal import CodeEditTextView

/// Replacements to make through the editor (a rename, a fix, formatting): undoable as one step, the caret kept.
/// Each `id` is applied once.
public struct EditorEdits: Equatable, Sendable {
    public let id: Int
    /// UTF-16 ranges of the current buffer, each with its new text.
    public let ranges: [NSRange]
    public let texts: [String]

    public init(id: Int, changes: [(NSRange, String)]) {
        self.id = id
        self.ranges = changes.map(\.0)
        self.texts = changes.map(\.1)
    }
}

/// A menu to open at the caret (code actions). Each `id` opens once; the pick (or nil) goes to `onMenuPick`.
public struct EditorMenu: Equatable, Sendable {
    public let id: Int
    public let titles: [String]
    /// A divider goes above this item (fixes above it, the rest below).
    public let dividerBefore: Int?

    public init(id: Int, titles: [String], dividerBefore: Int?) {
        self.id = id
        self.titles = titles
        self.dividerBefore = dividerBefore
    }
}

/// Receives the menu's pick: NSMenuItem needs an Objective-C target.
private final class MenuTarget: NSObject {
    var picked: Int?
    @objc func pick(_ item: NSMenuItem) { picked = item.tag }
}

extension EditorHost.Coordinator {
    /// The rect of the caret at `offset`, top-left origin, in the editor view (where cards are anchored).
    func caretFrame(_ controller: TextViewController, _ offset: Int) -> CGRect? {
        guard let rect = controller.textView.layoutManager.rectForOffset(offset) else { return nil }
        let view: NSView = controller.view
        var frame = view.convert(rect, from: controller.textView)
        if !view.isFlipped { frame.origin.y = view.bounds.height - frame.maxY }
        return frame
    }

    func apply(_ edits: EditorEdits?) {
        guard let edits, edits.id != appliedEditsID, let textView = controller?.textView else { return }
        appliedEditsID = edits.id
        let length = textView.textStorage.length
        textView.undoManager?.beginUndoGrouping()
        // Last first, so each range still means what it meant in the buffer the edits were made against.
        for (range, text) in zip(edits.ranges, edits.texts).sorted(by: { $0.0.location > $1.0.location })
        where NSMaxRange(range) <= length {
            textView.replaceCharacters(in: range, with: text)
        }
        textView.undoManager?.endUndoGrouping()
        onEditsApplied(edits.id)
    }

    /// Opens `menu` under the caret: AppKit's own menu, so it reads as the system's and the keyboard drives it.
    func open(_ menu: EditorMenu?) {
        guard let menu, menu.id != openedMenuID else { return }
        openedMenuID = menu.id
        guard let controller, let caret = controller.cursorPositions.first?.range.location,
            let rect = controller.textView.layoutManager.rectForOffset(caret)
        else { return onMenuPick(nil) }
        let target = MenuTarget()
        let nsMenu = NSMenu()
        for (index, title) in menu.titles.enumerated() {
            if index == menu.dividerBefore { nsMenu.addItem(.separator()) }
            let item = NSMenuItem(title: title, action: #selector(MenuTarget.pick(_:)), keyEquivalent: "")
            item.target = target
            item.tag = index
            nsMenu.addItem(item)
        }
        // After SwiftUI's update: the menu runs its own tracking loop until it closes.
        DispatchQueue.main.async { [weak self, textView = controller.textView] in
            nsMenu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.maxY), in: textView)
            self?.onMenuPick(target.picked)
        }
    }
}
