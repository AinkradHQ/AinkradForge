import AppKit
@preconcurrency internal import CodeEditTextView

/// Reports the pointer resting on a word: its first UTF-16 offset and its rect, top-left origin, in the
/// editor view's coordinates (where the caller anchors a card). Moving to another word, holding ⌘ (that is
/// jump-to-definition's), scrolling or typing ends it; leaving the editor ends it unless the pointer went
/// into another window — the card itself. Holding ⌥ reports at once (the quick help, mockup 09).
@MainActor
final class HoverTracker: NSResponder {
    var onHover: ((Int, CGRect)?) -> Void = { _ in }
    private weak var textView: TextView?
    private weak var container: NSView?
    private var word: NSRange?
    private var pending: Task<Void, Never>?
    private var scrollObserver: (any NSObjectProtocol)?

    override init() { super.init() }
    required init?(coder: NSCoder) { nil }

    func attach(to textView: TextView, container: NSView, scrollView: NSScrollView) {
        self.textView = textView
        self.container = container
        textView.addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self))
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.dismiss() } }
    }

    override func mouseMoved(with event: NSEvent) {
        guard let textView else { return }
        let point = textView.convert(event.locationInWindow, from: nil)
        let range = event.modifierFlags.contains(.command) ? nil : wordRange(at: point)
        let delay = Self.delay(for: event.modifierFlags)
        guard range != word else {
            // ⌥ pressed while resting: no more waiting.
            if let range, pending != nil, delay == .zero {
                pending?.cancel()
                report(range)
            }
            return
        }
        dismiss()
        guard let range else { return }
        word = range
        guard delay > .zero else { return report(range) }
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.report(range)
        }
    }

    override func mouseExited(with event: NSEvent) {
        let under = NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0)
        if word != nil, pending == nil, under != 0, under != textView?.window?.windowNumber { return }
        dismiss()
    }

    /// How long the pointer rests before the card shows: none while ⌥ is held.
    static func delay(for modifiers: NSEvent.ModifierFlags) -> Duration {
        modifiers.contains(.option) ? .zero : .milliseconds(500)
    }

    func dismiss() {
        pending?.cancel()
        pending = nil
        guard word != nil else { return }
        word = nil
        onHover(nil)
    }

    private func report(_ range: NSRange) {
        pending = nil
        guard let textView, let container, let rect = textView.layoutManager.rectsFor(range: range).first else { return }
        var frame = container.convert(rect, from: textView)
        if !container.isFlipped { frame.origin.y = container.bounds.height - frame.maxY }
        onHover((range.location, frame))
    }

    /// The identifier under `point` — over its glyphs, not merely nearest to them (past a line's end).
    private func wordRange(at point: CGPoint) -> NSRange? {
        guard let textView, let offset = textView.layoutManager.textOffsetAtPoint(point) else { return nil }
        let text = textView.textStorage.string as NSString
        func isWord(_ index: Int) -> Bool {
            let unit = text.character(at: index)
            return unit == 95 || (UnicodeScalar(unit).map { CharacterSet.alphanumerics.contains($0) } ?? false)
        }
        guard offset < text.length, isWord(offset) else { return nil }
        var start = offset
        var end = offset + 1
        while start > 0, isWord(start - 1) { start -= 1 }
        while end < text.length, isWord(end) { end += 1 }
        let range = NSRange(location: start, length: end - start)
        guard let rect = textView.layoutManager.rectsFor(range: range).first, rect.insetBy(dx: -1, dy: -1).contains(point)
        else { return nil }
        return range
    }
}
