import AppKit
import Foundation
import Observation

/// The workspace's tasks, which are running (each in its own terminal tab), and how each last went.
@MainActor
@Observable
final class TaskRunner {
    struct Result: Equatable {
        let succeeded: Bool
        let exitCode: Int32?
        let seconds: Int
        let at: Date
    }

    private(set) var tasks: [WorkspaceTask] = []
    /// Task id → its terminal tab, while it runs.
    private(set) var running: [String: Int] = [:]
    private(set) var results: [String: Result] = [:]
    private(set) var last: WorkspaceTask?
    /// Task id → when it started, while it runs.
    @ObservationIgnored private(set) var started: [String: Date] = [:]
    /// The clock (tests freeze it).
    @ObservationIgnored var now: () -> Date = Date.init

    func reset() {
        tasks = []
        running = [:]
        results = [:]
        last = nil
        started = [:]
    }

    /// Re-reads the tasks (the workspace's files changed).
    func refresh(root: URL, files: [String]) async {
        tasks = await Task.detached(priority: .utility) { TaskCatalog.detect(root: root, files: files) }.value
    }

    /// Runs `task` in a new terminal tab (a running one is shown instead of started twice).
    func run(_ task: WorkspaceTask, in drawer: TerminalDrawer) {
        if let tab = running[task.id], drawer.tabs.contains(where: { $0.id == tab }) { return drawer.select(tab) }
        guard let tab = drawer.add(command: task.command, title: task.shows) else { return }
        running[task.id] = tab
        started[task.id] = now()
        last = task
    }

    func stop(_ task: WorkspaceTask, in drawer: TerminalDrawer) {
        guard let tab = running.removeValue(forKey: task.id) else { return }
        drawer.close(tab)
    }

    /// Hears from the drawer when a terminal's process ends or its tab closes.
    func follow(_ drawer: TerminalDrawer, model: ForgeModel) {
        drawer.onEnded = { [weak self] tab, code in self?.ended(tab: tab, exitCode: code) }
        drawer.onClosed = { [weak self] tab in self?.tabClosed(tab) }
        drawer.onOpenLink = { [weak model] link in model?.openTerminalLink(link) }
    }

    /// A terminal's process ended: if it was a task's, keep how it went.
    func ended(tab: Int, exitCode: Int32?) {
        guard let id = running.first(where: { $0.value == tab })?.key else { return }
        running[id] = nil
        let seconds = Int(now().timeIntervalSince(started.removeValue(forKey: id) ?? now()))
        results[id] = Result(succeeded: exitCode == 0, exitCode: exitCode, seconds: seconds, at: now())
    }

    /// The task's tab was closed by hand while it ran: it stopped.
    func tabClosed(_ tab: Int) {
        if let id = running.first(where: { $0.value == tab })?.key { running[id] = nil }
    }
}

extension TaskRunner {
    /// How long a running task has run: `0:18`, `12:05`, `1:02:03`; nil when it is not running.
    func elapsed(_ id: String) -> String? {
        guard let start = started[id] else { return nil }
        let total = max(0, Int(now().timeIntervalSince(start)))
        let (h, m, s) = (total / 3_600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

extension ForgeModel {
    func runTask(_ task: WorkspaceTask) {
        palette = nil
        tasks.run(task, in: terminals)
    }

    /// ⇧⌥⌘R: the last task again (from the list when none has run yet).
    func rerunLastTask() {
        if let last = tasks.last { runTask(last) } else { palette = "!" }
    }

    /// ⌘-click in a terminal: a workspace file opens in the editor at its line; anything else opens as the
    /// system would.
    func openTerminalLink(_ link: String) {
        guard let parsed = TerminalLink.parse(link), let root = workspace?.root else { return }
        switch parsed {
        case .url(let url): NSWorkspace.shared.open(url)
        case .file(let path, let line):
            let absolute = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appending(path: path)
            let base = root.standardizedFileURL.path + "/"
            let full = absolute.standardizedFileURL.path
            guard full.hasPrefix(base) else { return NSWorkspace.shared.activateFileViewerSelecting([absolute]) }
            open(file: String(full.dropFirst(base.count)), pinned: true)
            if let line { pendingLine = line }
        }
    }

    /// The drawer's Tasks tab.
    func showTasks() {
        terminals.isOpen = true
        terminals.showsTasks = true
    }
}
