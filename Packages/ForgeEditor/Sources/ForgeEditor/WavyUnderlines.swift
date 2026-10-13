import AppKit
@preconcurrency internal import CodeEditTextView

/// Diagnostics as a wavy underline in their severity's colour (CSS `underline wavy`): drawn over the text
/// view, which CodeEdit's emphasis manager (straight lines only) cannot do. Never takes a click.
final class WavyUnderlineView: NSView {
    weak var textView: TextView?
    var marks: [EditorMark] = [] { didSet { if oldValue != marks { needsDisplay = true } } }

    private var frameObserver: (any NSObjectProtocol)?

    /// Over the whole text view, following its size by notification — no autoresizing constraints, which would
    /// join the text view's layout passes (and loop with the gutter's).
    func install(in textView: TextView) {
        self.textView = textView
        translatesAutoresizingMaskIntoConstraints = false
        textView.addSubview(self)
        frame = textView.bounds
        textView.postsFrameChangedNotifications = true
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: textView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let textView = self.textView, self.frame != textView.bounds else { return }
                self.frame = textView.bounds
            }
        }
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let layout = textView?.layoutManager, let length = textView?.textStorage.length else { return }
        let lineHeight = layout.estimateLineHeight()
        // Where the emphasis manager puts its straight underline, 3 pt under the glyphs' baseline area.
        let inset = (lineHeight - lineHeight / layout.lineHeightMultiplier) / 4
        for mark in marks where mark.range.location < length {
            let range = NSRange(location: mark.range.location, length: max(1, min(mark.range.length, length - mark.range.location)))
            let path = NSBezierPath()
            path.lineWidth = 1
            for rect in layout.rectsFor(range: range) where rect.insetBy(dx: 0, dy: -4).intersects(dirtyRect) {
                Self.wave(in: path, from: rect.minX, to: rect.maxX, y: rect.maxY - inset)
            }
            mark.color.setStroke()
            path.stroke()
        }
    }

    /// A 4 pt wavelength, ±1.5 pt zigzag smoothed into curves.
    static func wave(in path: NSBezierPath, from start: CGFloat, to end: CGFloat, y: CGFloat) {
        let half: CGFloat = 2, amplitude: CGFloat = 1.5
        var x = start
        var up = true
        path.move(to: NSPoint(x: x, y: y))
        while x < end {
            let next = min(x + half, end)
            path.curve(
                to: NSPoint(x: next, y: y), controlPoint1: NSPoint(x: x + half / 2, y: y + (up ? -amplitude : amplitude)),
                controlPoint2: NSPoint(x: next - half / 2, y: y + (up ? -amplitude : amplitude)))
            up.toggle()
            x = next
        }
    }
}
