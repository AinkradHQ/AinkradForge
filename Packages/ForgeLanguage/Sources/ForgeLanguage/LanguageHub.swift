import Foundation
internal import LanguageServerProtocol
import Observation

/// One diagnostic, as Forge shows it.
public struct Issue: Identifiable, Equatable, Sendable {
    @frozen public enum Severity: Int, Comparable, Sendable {
        case error = 1, warning, information, hint
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    public let path: String
    /// 0-based, as LSP reports them.
    public let start: (line: Int, character: Int)
    public let end: (line: Int, character: Int)
    public let severity: Severity
    public let message: String
    public let source: String?

    public var id: String { "\(path):\(start.line):\(start.character):\(message)" }

    public static func == (a: Issue, b: Issue) -> Bool { a.id == b.id && a.severity == b.severity }
}

/// The window's language servers: one session per server the workspace's open files need, started on demand.
/// Calls to a session are chained so they reach it in order; edits are debounced into full-text changes.
@MainActor
@Observable
public final class LanguageHub {
    /// Workspace-relative path → its issues, worst first.
    public private(set) var issues: [String: [Issue]] = [:]
    /// Server id → state, for every server an open file has asked for.
    public private(set) var statuses: [String: ServerStatus] = [:]
    /// Path overrides from settings (server id → executable).
    public var overrides: [String: String] = [:]

    @ObservationIgnored private var root: URL?
    @ObservationIgnored private var sessions: [String: LanguageSession] = [:]
    @ObservationIgnored private var chains: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingChanges: [String: Task<Void, Never>] = [:]

    public var allIssues: [Issue] { issues.values.flatMap { $0 }.sorted { ($0.severity, $0.path) < ($1.severity, $1.path) } }
    public var errorCount: Int { issues.values.reduce(0) { $0 + $1.filter { $0.severity == .error }.count } }
    public var warningCount: Int { issues.values.reduce(0) { $0 + $1.filter { $0.severity == .warning }.count } }

    public init() {}

    public func begin(root: URL) {
        end()
        self.root = root
    }

    /// Stops every server (closing or switching the workspace).
    public func end() {
        for session in sessions.values { Task { await session.shutdown() } }
        sessions = [:]
        chains = [:]
        pendingChanges.values.forEach { $0.cancel() }
        pendingChanges = [:]
        issues = [:]
        statuses = [:]
        root = nil
    }

    public func opened(path: String, text: String) {
        guard let (spec, languageID) = LanguageRegistry.server(for: path), let uri = uri(for: path) else { return }
        guard let session = session(for: spec) else { return }
        enqueue(spec.id) { await session.open(uri: uri, languageID: languageID, text: text) }
    }

    /// A buffer changed: after a short pause the server gets the whole text (`text` is read then, not now).
    public func changed(path: String, text: @escaping @MainActor () -> String) {
        guard let (spec, _) = LanguageRegistry.server(for: path), let uri = uri(for: path), let session = sessions[spec.id]
        else { return }
        pendingChanges[path]?.cancel()
        pendingChanges[path] = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let current = text()
            enqueue(spec.id) { await session.change(uri: uri, text: current) }
        }
    }

    public func saved(path: String) {
        guard let (spec, _) = LanguageRegistry.server(for: path), let uri = uri(for: path), let session = sessions[spec.id]
        else { return }
        enqueue(spec.id) { await session.save(uri: uri) }
    }

    public func closed(path: String) {
        pendingChanges.removeValue(forKey: path)?.cancel()
        guard let (spec, _) = LanguageRegistry.server(for: path), let uri = uri(for: path), let session = sessions[spec.id]
        else { return }
        enqueue(spec.id) { await session.close(uri: uri) }
    }

    public func restart(_ specID: String) {
        guard let session = sessions[specID] else { return }
        enqueue(specID) { await session.restart() }
    }

    // MARK: - Internals

    /// The session for a server, started the first time a file needs it; nil (and "not installed") when the
    /// executable is nowhere to be found.
    private func session(for spec: ServerSpec) -> LanguageSession? {
        if let existing = sessions[spec.id] { return existing }
        guard let root else { return nil }
        guard let executable = ShellEnvironment.locate(overrides[spec.id] ?? spec.command) else {
            statuses[spec.id] = .notInstalled
            return nil
        }
        let session = LanguageSession(spec: spec, root: root, executable: executable)
        sessions[spec.id] = session
        statuses[spec.id] = .starting
        Task { [weak self] in
            for await event in session.events {
                self?.handle(event, from: spec)
            }
        }
        enqueue(spec.id) { await session.start() }
        return session
    }

    private func handle(_ event: LanguageSession.Event, from spec: ServerSpec) {
        switch event {
        case .status(let status):
            statuses[spec.id] = status
        case .diagnostics(let uri, let diagnostics):
            guard let path = path(for: uri) else { return }
            let mapped = diagnostics.map { d in
                Issue(
                    path: path, start: (d.range.start.line, d.range.start.character),
                    end: (d.range.end.line, d.range.end.character),
                    severity: Issue.Severity(rawValue: d.severity?.rawValue ?? 1) ?? .error, message: d.message,
                    source: d.source)
            }
            issues[path] = mapped.isEmpty ? nil : mapped.sorted { ($0.severity, $0.start.line) < ($1.severity, $1.start.line) }
        }
    }

    /// Runs `operation` after everything already queued for that server.
    private func enqueue(_ specID: String, _ operation: @escaping @Sendable () async -> Void) {
        let previous = chains[specID]
        chains[specID] = Task {
            await previous?.value
            await operation()
        }
    }

    private func uri(for path: String) -> String? { root?.appending(path: path).absoluteString }

    private func path(for uri: String) -> String? {
        guard let root, let url = URL(string: uri) else { return nil }
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let full = url.standardizedFileURL.resolvingSymlinksInPath().path
        return full.hasPrefix(base) ? String(full.dropFirst(base.count)) : nil
    }
}
