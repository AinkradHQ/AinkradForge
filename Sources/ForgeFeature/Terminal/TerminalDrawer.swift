import AinkradAppKit
import AppKit
import Darwin
import Foundation
import Observation
@preconcurrency import SwiftTerm

/// The terminals under the editors. The model owns each terminal view (and so its process): hiding the
/// drawer or switching tabs only takes the view off screen, so terminals keep running until closed or the
/// workspace closes.
@MainActor
@Observable
final class TerminalDrawer {
    struct Tab: Identifiable, Equatable {
        let id: Int
        let title: String
        /// What a task tab runs; nil for an interactive shell.
        let command: String?
        var ended = false
        var exitCode: Int32?
    }

    var isOpen = false
    var isMaximised = false
    /// The drawer shows the task list instead of a terminal.
    var showsTasks = false
    var height: Double = 270
    private(set) var tabs: [Tab] = []
    var active: Int?
    /// A busy terminal the user asked to close; the window confirms first.
    var confirmingClose: Int?
    /// Bumped to move the keyboard into the active terminal.
    private(set) var focusRequest = 0
    @ObservationIgnored private var views: [Int: ForgeTerminalView] = [:]
    @ObservationIgnored private var events: [Int: TerminalEvents] = [:]
    @ObservationIgnored private var nextID = 1
    @ObservationIgnored private var root: URL?
    @ObservationIgnored var palette: HostTerminalPalette?
    /// A command's process ended (tab, exit code) / a tab was closed — for the task runner.
    @ObservationIgnored var onEnded: (Int, Int32?) -> Void = { _, _ in }
    @ObservationIgnored var onClosed: (Int) -> Void = { _ in }
    /// ⌘-click on a path or URL in a terminal's output.
    @ObservationIgnored var onOpenLink: (String) -> Void = { _ in }
    @ObservationIgnored private var routers: [Int: LinkRouter] = [:]
    @ObservationIgnored private var scrollMonitor: Any?
    @ObservationIgnored private var hideScroller: Task<Void, Never>?
    /// The theme's text colour, for a palette that leaves the terminal's foreground unset (Liquid Glass does).
    @ObservationIgnored var foreground: NSColor?

    func begin(root: URL) {
        end()
        self.root = root
    }

    /// Ends every terminal (the workspace closed or switched).
    func end() {
        views.values.forEach { $0.terminate() }
        views = [:]
        events = [:]
        routers = [:]
        tabs = []
        active = nil
        isOpen = false
        isMaximised = false
        root = nil
    }

    /// ⌃`: shows the drawer (with a shell, if it has none) and focuses it, or hides it.
    func toggle() {
        if isOpen {
            isOpen = false
        } else {
            isOpen = true
            if tabs.isEmpty { add() } else { focusRequest += 1 }
        }
    }

    /// A new terminal in the workspace folder: the login shell, or `command` run by it (a task).
    @discardableResult
    func add(command: String? = nil, title: String? = nil) -> Int? {
        guard let root else { return nil }
        let id = nextID
        nextID += 1
        let view = ForgeTerminalView(frame: .zero)
        let handler = TerminalEvents(id: id, drawer: self)
        view.processDelegate = handler
        let router = LinkRouter(view: view) { [weak self] link in self?.onOpenLink(link) }
        view.terminalDelegate = router
        routers[id] = router
        Self.apply(palette, foreground: foreground, to: view)
        let shell = Self.shell
        // Spawned at the first real size, so the shell starts matching the drawer (no startup resize).
        view.onReady = { [weak view] in
            view?.startProcess(
                executable: shell, args: command.map { ["-l", "-c", $0] } ?? ["-l"], environment: nil,
                currentDirectory: root.path(percentEncoded: false))
        }
        views[id] = view
        events[id] = handler
        watchScrolling()
        tabs.append(Tab(id: id, title: title ?? (shell as NSString).lastPathComponent, command: command))
        active = id
        isOpen = true
        showsTasks = false
        focusRequest += 1
        return id
    }

    func view(_ id: Int) -> ForgeTerminalView? { views[id] }

    func select(_ id: Int) {
        active = id
        showsTasks = false
        focusRequest += 1
    }

    /// ✕: ends the terminal, after asking when something still runs in it.
    func requestClose(_ id: Int) {
        if isBusy(id) { confirmingClose = id } else { close(id) }
    }

    func close(_ id: Int) {
        confirmingClose = nil
        views.removeValue(forKey: id)?.terminate()
        events[id] = nil
        routers[id] = nil
        tabs.removeAll { $0.id == id }
        onClosed(id)
        if active == id { active = tabs.last?.id }
        if tabs.isEmpty && !showsTasks {
            isOpen = false
            isMaximised = false
        }
    }

    /// The process ended: a shell's tab goes (as when typing `exit`); a task's stays, showing how it went.
    func ended(_ id: Int, exitCode: Int32?) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        guard tabs[index].command != nil else { return close(id) }
        tabs[index].ended = true
        tabs[index].exitCode = exitCode.map(Self.exitStatus)
        onEnded(id, tabs[index].exitCode)
    }

    /// SwiftTerm reports the raw wait status: the exit code is its second byte; a signal (low 7 bits) is
    /// reported as 128 + the signal, as shells do.
    static func exitStatus(_ status: Int32) -> Int32 {
        let signal = status & 0x7F
        return signal == 0 ? (status >> 8) & 0xFF : 128 + signal
    }

    /// Something still runs: a task that has not ended, or a shell with a child process.
    func isBusy(_ id: Int) -> Bool {
        guard let tab = tabs.first(where: { $0.id == id }), !tab.ended else { return false }
        if tab.command != nil { return true }
        guard let pid = views[id]?.process?.shellPid, pid > 0 else { return false }
        return Self.hasChildren(pid)
    }

    /// Applies the theme's terminal palette to every terminal.
    func restyle(_ palette: HostTerminalPalette?, foreground: NSColor) {
        self.palette = palette
        self.foreground = foreground
        views.values.forEach { Self.apply(palette, foreground: foreground, to: $0) }
    }

    /// Shows a terminal's scroller while it is scrolled, and hides it a moment after — as Rune does. One
    /// monitor for every terminal in the drawer.
    private func watchScrolling() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { self?.scrolled(event) }
            return event
        }
    }

    private func scrolled(_ event: NSEvent) {
        guard let view = views.values.first(where: { view in
            view.window === event.window && view.bounds.contains(view.convert(event.locationInWindow, from: nil))
        }), let scroller = view.subviews.compactMap({ $0 as? NSScroller }).first
        else { return }
        scroller.scrollerStyle = .overlay
        scroller.isHidden = false
        hideScroller?.cancel()
        hideScroller = Task { [weak scroller] in
            try? await Task.sleep(for: .seconds(1.1))
            guard !Task.isCancelled else { return }
            scroller?.isHidden = true
        }
    }

    // MARK: - Support

    /// `$SHELL` when /etc/shells lists it, else zsh — as Rune resolves it.
    static var shell: String {
        let listed = (try? String(contentsOfFile: "/etc/shells", encoding: .utf8))?
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        if let shell = ProcessInfo.processInfo.environment["SHELL"], listed.contains(shell) { return shell }
        return "/bin/zsh"
    }

    private static func hasChildren(_ pid: pid_t) -> Bool {
        var children = [pid_t](repeating: 0, count: 16)
        let bytes = proc_listchildpids(pid, &children, Int32(children.count * MemoryLayout<pid_t>.size))
        return bytes > 0
    }

    /// The theme's terminal colours (the ones Rune uses), on a clear background so the drawer's surface shows.
    static func apply(_ palette: HostTerminalPalette?, foreground: NSColor?, to view: ForgeTerminalView) {
        // Rune's default font, when installed: a Nerd Font, so powerline / p10k prompt glyphs draw instead of "?" (E0 FD11).
        // ponytail: fixed family, follow Rune's font setting if Forge grows terminal settings of its own.
        view.font = NSFont(name: "MesloLGS NF", size: 12) ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        // Layer-backed with a clear layer, as Rune does: otherwise the view paints an opaque backdrop.
        view.wantsLayer = true
        view.layer?.isOpaque = false
        view.layer?.backgroundColor = .clear
        view.nativeBackgroundColor = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.004)  // design-lint: allow raw-color near-clear terminal background
        // SwiftTerm's own scroller (not an overlay one): hidden until the terminal is scrolled (`watchScrolling`).
        view.subviews.compactMap { $0 as? NSScroller }.forEach { $0.isHidden = true }
        let ansi = palette?.ansi.compactMap(color(hex:)) ?? []
        if ansi.count == 16 { view.installColors(ansi) }
        if let text = palette.flatMap({ EditorPalette.color(hex: $0.foreground) }) ?? foreground { view.nativeForegroundColor = text }
        if let cursor = palette.flatMap({ EditorPalette.color(hex: $0.cursor) }) { view.caretColor = cursor }
    }

    private static func color(hex: String) -> SwiftTerm.Color? {
        guard let color = EditorPalette.color(hex: hex)?.usingColorSpace(.sRGB) else { return nil }
        func channel(_ value: CGFloat) -> UInt16 { UInt16(max(0, min(1, value)) * 65_535) }
        return SwiftTerm.Color(  // design-lint: allow raw-color SwiftTerm ANSI from host.theme.terminalPalette
            red: channel(color.redComponent), green: channel(color.greenComponent), blue: channel(color.blueComponent))
    }
}

/// A terminal that starts its process at its first usable size (see `TerminalDrawer.add`).
final class ForgeTerminalView: LocalProcessTerminalView {
    var onReady: (() -> Void)?
    private var started = false

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // A usable size, not merely a non-zero one: a layout pass can hand out a sliver first, and a process
        // started at two columns keeps that layout (the fork does not reflow).
        guard !started, newSize.width > 100, newSize.height > 40 else { return }
        started = true
        onReady?()
        onReady = nil
    }
}

/// Process events for one terminal, back to the drawer on the main actor.
private final class TerminalEvents: NSObject, LocalProcessTerminalViewDelegate, @unchecked Sendable {
    let id: Int
    weak var drawer: TerminalDrawer?

    init(id: Int, drawer: TerminalDrawer) {
        self.id = id
        self.drawer = drawer
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        let id = id
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.drawer?.ended(id, exitCode: exitCode) }
        }
    }
}

/// Stands in as the terminal's view delegate only to catch ⌘-clicked links: SwiftTerm opens them through a
/// protocol default that a subclass cannot override. Everything else goes back to the terminal view itself.
private final class LinkRouter: NSObject, TerminalViewDelegate {
    weak var view: LocalProcessTerminalView?
    let open: (String) -> Void

    init(view: LocalProcessTerminalView, open: @escaping (String) -> Void) {
        self.view = view
        self.open = open
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) { open(link) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { view?.sizeChanged(source: source, newCols: newCols, newRows: newRows) }
    func setTerminalTitle(source: TerminalView, title: String) { view?.setTerminalTitle(source: source, title: title) }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) { view?.hostCurrentDirectoryUpdate(source: source, directory: directory) }
    func send(source: TerminalView, data: ArraySlice<UInt8>) { view?.send(source: source, data: data) }
    func scrolled(source: TerminalView, position: Double) { view?.scrolled(source: source, position: position) }
    func clipboardCopy(source: TerminalView, content: Data) { view?.clipboardCopy(source: source, content: content) }
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) { view?.rangeChanged(source: source, startY: startY, endY: endY) }
    func bell(source: TerminalView) { NSSound.beep() }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
}

/// A ⌘-clicked terminal link: a file (with its line and column, as compilers print them) or something else.
enum TerminalLink: Equatable {
    case file(path: String, line: Int?)
    case url(URL)

    /// `/a/b.swift:12:5: error`, `./x.ts:3`, `file:///a/b`, `~/notes.md`, or a web URL.
    static func parse(_ link: String, home: String = NSHomeDirectory()) -> TerminalLink? {
        var text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("file://"), let url = URL(string: text) { text = url.path(percentEncoded: false) }
        if text.hasPrefix("~/") { text = home + text.dropFirst() }
        guard text.hasPrefix("/") || text.hasPrefix("./") || text.hasPrefix("../") else {
            return URL(string: text).flatMap { $0.scheme == nil ? nil : .url($0) }
        }
        // Trailing `:line` and `:line:column` (the column is not used: the editor goes to the line).
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        var numbers: [Int] = []
        var end = parts.count
        while end > 1, let number = Int(parts[end - 1]), numbers.count < 2 {
            numbers.insert(number, at: 0)
            end -= 1
        }
        return .file(path: parts[..<end].joined(separator: ":"), line: numbers.first)
    }
}

