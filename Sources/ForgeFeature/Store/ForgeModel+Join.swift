import Foundation

extension ForgeModel {
    /// Join All Splits: the second pane's tabs move into the first, which then shows the file that was in front.
    func joinSplits() {
        guard panes.count > 1 else { return }
        let showing = tabs.active
        let moving = panes[1].paths
        focus(pane: 0)
        if let first = panes[0].active { activate(first) }
        for path in moving where !panes[0].paths.contains(path) { open(file: path, pinned: true) }
        focus(pane: 1)
        closePane()
        stacked = false
        if let showing { activate(showing) }
    }
}
