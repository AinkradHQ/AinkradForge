import AppKit
@preconcurrency internal import CodeEditTextView

extension EditorHost.Coordinator {
    static let flashGroup = "forge.flash"

    /// A jump to a line (go to line, an issue, a launch from Grimoire) washes the line for a second, so the eye
    /// lands on it (E1D2 FD43, mockup 11).
    /// ponytail: a newer flash within the second is cleared with the older one; keep a generation if that shows.
    func flash(line: Int) {
        guard let textView = controller?.textView, let manager = textView.emphasisManager,
            let row = textView.layoutManager.textLineForIndex(line - 1)
        else { return }
        let color = colors?.selection ?? .selectedTextBackgroundColor
        manager.replaceEmphases([Emphasis(range: row.range, style: .outline(color: color, fill: true))], for: Self.flashGroup)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak manager] in manager?.removeEmphases(for: Self.flashGroup) }
    }
}
