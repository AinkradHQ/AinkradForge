import AppKit
@preconcurrency internal import CodeEditSourceEditor
@preconcurrency internal import CodeEditTextView

/// Full-width line washes (mockup 15: an outside change's lines filled edge to edge). It sits in the scroll
/// view's clip view just below the text view, at the text view's frame — so it scrolls with the text and the
/// text draws over it. An emphasis can't do this: CodeEdit's fills end at the text.
final class LineWashView: NSView {
    weak var textView: TextView?
    var washes: [EditorMark] = [] { didSet { if oldValue != washes { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let layout = textView?.layoutManager, let context = NSGraphicsContext.current?.cgContext else { return }
        for wash in washes {
            guard let first = layout.textLineForOffset(wash.range.location),
                let last = layout.textLineForOffset(max(wash.range.location, wash.range.location + wash.range.length - 1))
            else { continue }
            let rect = NSRect(x: 0, y: first.yPos, width: bounds.width, height: last.yPos + last.height - first.yPos)
            guard rect.intersects(dirtyRect) else { continue }
            context.setFillColor(wash.color.cgColor)
            context.fill(rect)
        }
    }
}

extension EditorHost.Coordinator {
    /// Puts the wash view under the text view, following its frame (it grows with the document).
    func installLineWash(_ controller: TextViewController) {
        guard let textView = controller.textView, let clip = textView.superview, lineWashView.superview !== clip else { return }
        lineWashView.textView = textView
        clip.addSubview(lineWashView, positioned: .below, relativeTo: textView)
        let place: @MainActor @Sendable () -> Void = { [weak textView, weak lineWashView] in
            guard let textView, let lineWashView else { return }
            lineWashView.frame = textView.frame
            lineWashView.needsDisplay = true
        }
        place()
        textView.postsFrameChangedNotifications = true
        washObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: textView, queue: .main
        ) { _ in MainActor.assumeIsolated { place() } }
    }
}
