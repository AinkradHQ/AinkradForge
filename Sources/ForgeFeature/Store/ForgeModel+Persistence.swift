import Foundation

/// What the window saves: the workspace's layout, and unsaved buffers across a quit (the host's quit prompt
/// cannot see them, so Forge keeps them instead).
extension ForgeModel {
    /// Every open path once, across panes.
    var activeDocument: EditorDocument? { tabs.active.flatMap { documents[$0] } }
    var openPaths: [String] { panes.flatMap(\.paths).reduce(into: []) { if !$0.contains($1) { $0.append($1) } } }
    var unsavedPaths: [String] { openPaths.filter { documents[$0]?.isDirty == true } }

    func persist() {
        guard let key = workspace?.root.path(percentEncoded: false) else { return }
        let state = ForgeDocument.WorkspaceState(
            tabs: panes[0], expanded: expanded, recentFiles: recentFiles, panes: panes, activePane: activePane,
            stacked: stacked)
        store.update { $0.workspaces[key] = state }
    }

    /// Hot exit: every dirty buffer's text goes where `restoreUnsaved` finds it when the file next loads.
    /// Backups of files not loaded this time (tabs never shown) are kept.
    /// The app quits or this window's Forge goes: what is still pending is saved — unsaved buffers backed up and
    /// a server path typed within its pause set (E1D5 FD71).
    func leave() {
        flushServerPaths()
        backupUnsaved()
    }

    func backupUnsaved() {
        guard let key = workspace?.root.path(percentEncoded: false) else { return }
        var buffers = store.unsaved(in: key).filter { documents[$0.key]?.state != .ready }
        for (path, document) in documents where document.isDirty { buffers[path] = document.storage.string }
        store.setUnsaved(buffers, in: key)
    }

    /// A buffer backed up at the last quit comes back unsaved, over the file's disk text.
    func restoreUnsaved(_ path: String, into document: EditorDocument) {
        guard let key = workspace?.root.path(percentEncoded: false) else { return }
        var buffers = store.unsaved(in: key)
        guard let text = buffers.removeValue(forKey: path) else { return }
        document.replaceText(text)
        store.setUnsaved(buffers, in: key)
    }
}
