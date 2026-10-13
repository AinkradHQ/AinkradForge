import Foundation

/// What another app hands Forge: a folder, a file at a line, or the review (`ForgeLaunch`).
extension ForgeModel {
    /// Opens a `ForgeLaunch` (folder, or file at a line; an open workspace stays — the host remounts to hand one in).
    /// Leaving an open workspace goes through `request`, which asks about unsaved files and running terminals (FD37).
    func start(launch: String? = nil) async {
        let request = ForgeLaunch.decode(launch)
        var isFolder: ObjCBool = false
        if let request, FileManager.default.fileExists(atPath: request.path, isDirectory: &isFolder) {
            let url = URL(fileURLWithPath: request.path)
            let folder = isFolder.boolValue ? url : url.deletingLastPathComponent()
            // A file opens its whole repo, when it is in one.
            let top = isFolder.boolValue ? nil : (try? await Git(directory: folder).run(["rev-parse", "--show-toplevel"]))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let target = top.map { URL(fileURLWithPath: $0) } ?? folder
            if workspace?.root.standardizedFileURL.path != target.standardizedFileURL.path {
                guard workspace == nil else { return self.request(.open(target, then: request)) }
                await open(folder: target)
            }
            land(request)
            return
        }
        guard workspace == nil, let path = store.document.lastWorkspace,
            FileManager.default.fileExists(atPath: path)
        else { return }
        await open(folder: URL(fileURLWithPath: path))
    }

    /// The file (at its line) or the review a launch asked for, in the workspace now open.
    func land(_ launch: ForgeLaunch) {
        let url = URL(fileURLWithPath: launch.path)
        if !url.hasDirectoryPath, let path = workspace?.relativePath(of: url) {
            reveal(path)
            open(file: path, pinned: true)
            pendingLine = launch.line
        }
        agent.reviewingAll = agent.reviewingAll || launch.review == true
    }
}
