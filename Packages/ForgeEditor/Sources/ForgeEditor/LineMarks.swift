import AppKit
@preconcurrency internal import CodeEditSourceEditor
@preconcurrency internal import CodeEditTextView

/// A change mark in the gutter: a bar beside `lines` (1-based), or — for removed lines — a notch below `line`
/// (above line 1 when it is 0).
public struct EditorLineMark: Equatable, Sendable {
    public let lines: ClosedRange<Int>
    public let color: NSColor
    public let isRemoval: Bool
    /// What a click reports back (e.g. the hunk's index).
    public let tag: Int

    public init(lines: ClosedRange<Int>, color: NSColor, isRemoval: Bool, tag: Int) {
        self.lines = lines
        self.color = color
        self.isRemoval = isRemoval
        self.tag = tag
    }
}

/// Draws the marks at the gutter's trailing edge. It lives inside CodeEdit's gutter, whose coordinates are the
/// document's (top-left origin), so the marks scroll with it; line positions come from the text layout.
final class LineMarkView: NSView {
    weak var textView: TextView?
    var marks: [EditorLineMark] = [] { didSet { if oldValue != marks { needsDisplay = true } } }
    var onClick: (Int, NSRect) -> Void = { _, _ in }
    static let width: CGFloat = 8

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let layout = textView?.layoutManager, let context = NSGraphicsContext.current?.cgContext else { return }
        for mark in marks {
            guard let rect = self.rect(of: mark, in: layout), rect.intersects(dirtyRect) else { continue }
            context.setFillColor(mark.color.cgColor)
            if mark.isRemoval {
                // A notch pointing into the text, on the boundary where lines went.
                context.beginPath()
                context.move(to: CGPoint(x: bounds.maxX - 6, y: rect.midY - 4))
                context.addLine(to: CGPoint(x: bounds.maxX, y: rect.midY))
                context.addLine(to: CGPoint(x: bounds.maxX - 6, y: rect.midY + 4))
                context.closePath()
                context.fillPath()
            } else {
                context.fill(rect)
            }
        }
    }

    /// The bar's rect (3 pt at the trailing edge), or a removal's 8 pt band centred on its boundary.
    private func rect(of mark: EditorLineMark, in layout: TextLayoutManager) -> NSRect? {
        if mark.isRemoval {
            let line = mark.lines.lowerBound
            let boundary: CGFloat
            if line <= 0 {
                boundary = layout.textLineForIndex(0)?.yPos ?? 0
            } else {
                guard let row = layout.textLineForIndex(line - 1) else { return nil }
                boundary = row.yPos + row.height
            }
            return NSRect(x: 0, y: boundary - 4, width: bounds.width, height: 8)
        }
        guard let first = layout.textLineForIndex(mark.lines.lowerBound - 1),
            let last = layout.textLineForIndex(mark.lines.upperBound - 1)
        else { return nil }
        return NSRect(x: bounds.maxX - 3, y: first.yPos, width: 3, height: last.yPos + last.height - first.yPos)
    }

    override func mouseDown(with event: NSEvent) {
        guard let layout = textView?.layoutManager else { return }
        let point = convert(event.locationInWindow, from: nil)
        for mark in marks {
            guard var rect = rect(of: mark, in: layout) else { continue }
            rect.origin.x = 0
            rect.size.width = bounds.width
            if rect.contains(point) { return onClick(mark.tag, rect) }
        }
        super.mouseDown(with: event)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

extension EditorHost.Coordinator {
    /// Puts the mark view in CodeEdit's gutter (found by type: the controller does not expose it), at its
    /// trailing edge, full height.
    func installLineMarks(_ controller: TextViewController) {
        func gutter(in view: NSView) -> GutterView? {
            (view as? GutterView) ?? view.subviews.lazy.compactMap(gutter(in:)).first
        }
        guard let gutter = gutter(in: controller.view), lineMarkView.superview !== gutter else { return }
        lineMarkView.textView = controller.textView
        gutter.addSubview(lineMarkView)
        // GutterView sets its own `frame` (so autoresizing never runs): follow it by notification.
        let place: @MainActor @Sendable () -> Void = { [weak gutter, weak lineMarkView] in
            guard let gutter, let lineMarkView else { return }
            lineMarkView.frame = NSRect(
                x: gutter.bounds.maxX - LineMarkView.width, y: 0, width: LineMarkView.width, height: gutter.bounds.height)
        }
        place()
        gutter.postsFrameChangedNotifications = true
        gutterObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: gutter, queue: .main
        ) { _ in MainActor.assumeIsolated { place() } }
    }

    /// A click on a mark: its tag and its rect in the editor view (top-left origin), for anchoring a card.
    func lineMarkClicked(_ tag: Int, _ rect: NSRect) {
        guard let view = controller?.view else { return }
        var frame = view.convert(rect, from: lineMarkView)
        if !view.isFlipped { frame.origin.y = view.bounds.height - frame.maxY }
        onLineMarkClick(tag, frame)
    }
}
