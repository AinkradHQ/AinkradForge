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

/// A place in the workspace a server pointed at (a definition, a reference).
public struct SymbolLocation: Sendable {
    /// Workspace-relative.
    public let path: String
    /// 0-based, as LSP reports them.
    public let start: (line: Int, character: Int)
    public let end: (line: Int, character: Int)
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
    /// Server id → what it is busy with ("Indexing 412 / 1280"), while it reports progress.
    public private(set) var progress: [String: String] = [:]
    /// Server id → its log, newest last (the last 500 lines): start, stop, and the server's own messages.
    @ObservationIgnored public private(set) var logs: [String: [String]] = [:]
    /// Server id → the characters after which it offers completions / signature help.
    public private(set) var completionTriggers: [String: Set<String>] = [:]
    public private(set) var signatureTriggers: [String: Set<String>] = [:]
    /// Makes an edit a server asked for (after a code action's command): workspace-relative path → changes.
    /// Returns whether it was made.
    @ObservationIgnored public var onApplyEdit: (@MainActor ([String: [TextChange]]) -> Bool)?
    /// Each file's diagnostics as the server sent them, handed back with a code-action request.
    @ObservationIgnored private var diagnostics: [String: [Diagnostic]] = [:]
    /// Path overrides from settings (server id → executable).
    public var overrides: [String: String] = [:]
    /// Servers the user set up for languages Forge has none for (generic stdio LSP), after Forge's own.
    public private(set) var custom: [ServerSpec] = []

    @ObservationIgnored private var root: URL?
    @ObservationIgnored var sessions: [String: LanguageSession] = [:]
    @ObservationIgnored private var chains: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingChanges: [String: Task<Void, Never>] = [:]
    /// The text reader of each pending change, so a request can send it at once instead of after the pause.
    @ObservationIgnored private var pendingTexts: [String: @MainActor () -> String] = [:]

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
        pendingTexts = [:]
        issues = [:]
        statuses = [:]
        progress = [:]
        logs = [:]
        completionTriggers = [:]
        signatureTriggers = [:]
        diagnostics = [:]
        root = nil
    }

    public func opened(path: String, text: String) {
        guard let (spec, languageID) = server(for: path), let uri = uri(for: path) else { return }
        guard let session = session(for: spec) else { return }
        enqueue(spec.id) { await session.open(uri: uri, languageID: languageID, text: text) }
    }

    /// A buffer changed: after a short pause the server gets the whole text (`text` is read then, not now).
    public func changed(path: String, text: @escaping @MainActor () -> String) {
        guard let (spec, _) = server(for: path), let uri = uri(for: path), let session = sessions[spec.id]
        else { return }
        pendingChanges[path]?.cancel()
        pendingTexts[path] = text
        pendingChanges[path] = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            flush(path)
        }
    }

    /// Sends a pending change now.
    private func flush(_ path: String) {
        pendingChanges.removeValue(forKey: path)?.cancel()
        guard let text = pendingTexts.removeValue(forKey: path), let (spec, _) = server(for: path),
            let uri = uri(for: path), let session = sessions[spec.id]
        else { return }
        let current = text()
        enqueue(spec.id) { await session.change(uri: uri, text: current) }
    }

    // MARK: - Requests: 0-based line and UTF-16 character, as LSP counts them

    public func hover(path: String, line: Int, character: Int) async -> String? {
        await request(path) { await $0.hover(uri: $1, line: line, character: character) } ?? nil
    }

    /// Definitions inside the workspace (a definition in an SDK or a dependency outside it is left out).
    public func definition(path: String, line: Int, character: Int) async -> [SymbolLocation] {
        let found = await request(path) { await $0.definition(uri: $1, line: line, character: character) } ?? []
        return locations(found)
    }

    /// Which servers this Mac has (a settings override first, then the login PATH): their commands, found and
    /// missing. Blocking (the first call reads the login shell's PATH) — call it off the main thread.
    public nonisolated static func availability(overrides: [String: String]) -> (found: [String], missing: [String]) {
        var found: [String] = [], missing: [String] = []
        for spec in LanguageRegistry.servers where !(found + missing).contains(spec.command) {
            if ShellEnvironment.locate(overrides[spec.id] ?? spec.command) != nil { found.append(spec.command) } else { missing.append(spec.command) }
        }
        return (found, missing)
    }

    /// The symbols enclosing a position, outermost first (`SidebarRow › body`) — the breadcrumb's tail.
    public func enclosingSymbols(path: String, line: Int, character: Int) async -> [String] {
        let outline = await request(path) { await $0.documentSymbols(uri: $1) } ?? []
        return Self.enclosing(outline, line: line, character: character)
    }

    /// Pure, so the nesting is tested without a server.
    nonisolated static func enclosing(_ symbols: [DocumentSymbol], line: Int, character: Int) -> [String] {
        func contains(_ range: LSPRange) -> Bool {
            (range.start.line, range.start.character) <= (line, character) && (line, character) <= (range.end.line, range.end.character)
        }
        guard let hit = symbols.first(where: { contains($0.range) }) else { return [] }
        return [hit.name] + enclosing(hit.children ?? [], line: line, character: character)
    }

    public func references(path: String, line: Int, character: Int) async -> [SymbolLocation] {
        let found = await request(path) { await $0.references(uri: $1, line: line, character: character) } ?? []
        return locations(found)
    }

    /// Completions at the caret, in the server's order.
    public func completions(path: String, line: Int, character: Int) async -> [Completion] {
        let items = await request(path) { await $0.completions(uri: $1, line: line, character: character) } ?? []
        return items.sorted { ($0.sortText ?? $0.label) < ($1.sortText ?? $1.label) }.map(Self.completion)
    }

    /// The call around the caret, or nil outside one.
    public func signatureHelp(path: String, line: Int, character: Int) async -> SignatureHint? {
        guard let help = await request(path, { await $0.signatureHelp(uri: $1, line: line, character: character) }) ?? nil,
            !help.signatures.isEmpty
        else { return nil }
        let signature = help.signatures[min(max(0, help.activeSignature ?? 0), help.signatures.count - 1)]
        let active = signature.activeParameter.map { Int($0) } ?? help.activeParameter ?? 0
        var range: NSRange?
        if let parameters = signature.parameters, parameters.indices.contains(active) {
            switch parameters[active].label {
            case .optionA(let text):
                let found = (signature.label as NSString).range(of: text)
                range = found.location == NSNotFound ? nil : found
            case .optionB(let offsets) where offsets.count == 2:
                range = NSRange(location: Int(offsets[0]), length: Int(offsets[1]) - Int(offsets[0]))
            default: break
            }
        }
        return SignatureHint(label: signature.label, activeParameter: range, documentation: signature.documentation.map(Self.text))
    }

    private static func completion(_ item: CompletionItem) -> Completion {
        var start: (Int, Int)?
        var newText: String?
        switch item.textEdit {
        case .optionA(let edit):
            start = (edit.range.start.line, edit.range.start.character)
            newText = edit.newText
        case .optionB(let edit):
            start = (edit.replace.start.line, edit.replace.start.character)
            newText = edit.newText
        case nil: break
        }
        let raw = newText ?? item.insertText ?? item.label
        let (insert, selection) = item.insertTextFormat == .snippet ? Snippet.parse(raw) : (raw, nil)
        return Completion(
            label: item.label, kind: kind(item.kind), detail: item.detail, documentation: item.documentation.map(text),
            insertText: insert, selection: selection,
            filterText: item.filterText ?? item.label, sortText: item.sortText ?? item.label, replaceStart: start,
            deprecated: item.deprecated == true)
    }

    private static func kind(_ kind: CompletionItemKind?) -> Completion.Kind {
        switch kind {
        case .method, .constructor: .method
        case .function, .operator: .function
        case .field, .property: .property
        case .variable, .value, .reference: .variable
        case .class, .interface, .enum, .struct, .typeParameter: .type
        case .keyword: .keyword
        case .snippet: .snippet
        case .module, .folder, .file: .module
        case .constant, .enumMember: .constant
        default: .other
        }
    }

    private static func text(_ documentation: TwoTypeOption<String, MarkupContent>) -> String {
        switch documentation {
        case .optionA(let text): text
        case .optionB(let markup): markup.value
        }
    }

    /// Every place renaming the symbol at the position would change (workspace-relative path → changes).
    public func rename(path: String, line: Int, character: Int, to newName: String) async -> [String: [TextChange]] {
        let edit = await request(path) { await $0.rename(uri: $1, line: line, character: character, to: newName) } ?? nil
        return edit.map { relative($0.textChanges) } ?? [:]
    }

    /// Fixes and refactors for a range: quick fixes first (the preferred one leading), then the rest.
    public func codeActions(
        path: String, from start: (line: Int, character: Int), to end: (line: Int, character: Int)
    ) async -> [CodeActionItem] {
        let range = LSPRange(start: Position(line: start.line, character: start.character), end: Position(line: end.line, character: end.character))
        let touching = (diagnostics[path] ?? []).filter { $0.range.start.line <= end.line && $0.range.end.line >= start.line }
        let found = await request(path) { await $0.codeActions(uri: $1, range: range, diagnostics: touching) } ?? []
        let items = found.compactMap { option -> CodeActionItem? in
            switch option {
            case .optionA(let command): CodeActionItem(title: command.title, kind: nil, isPreferred: false, action: option)
            case .optionB(let action):
                action.disabled == nil
                    ? CodeActionItem(title: action.title, kind: action.kind, isPreferred: action.isPreferred == true, action: option)
                    : nil
            }
        }
        return items.filter { $0.isQuickFix && $0.isPreferred } + items.filter { $0.isQuickFix && !$0.isPreferred }
            + items.filter { !$0.isQuickFix }
    }

    /// Carries out a code action: its edit comes back to be made; its command (if any) runs on the server, which
    /// may send further edits through `onApplyEdit`.
    public func perform(_ item: CodeActionItem, path: String) async -> [String: [TextChange]] {
        switch item.action {
        case .optionA(let command):
            _ = await request(path) { session, _ in await session.execute(command) }
            return [:]
        case .optionB(let action):
            if let command = action.command { _ = await request(path) { session, _ in await session.execute(command) } }
            return action.edit.map { relative($0.textChanges) } ?? [:]
        }
    }

    /// The edits that would format the whole file.
    public func format(path: String, tabSize: Int, insertSpaces: Bool) async -> [TextChange] {
        let edits = await request(path) { await $0.format(uri: $1, tabSize: tabSize, insertSpaces: insertSpaces) } ?? []
        return edits.map(TextChange.init)
    }

    /// Changes by URI → by workspace-relative path; files outside the workspace are left alone.
    private func relative(_ changes: [String: [TextChange]]) -> [String: [TextChange]] {
        var out: [String: [TextChange]] = [:]
        for (uri, list) in changes { if let path = path(for: uri) { out[path, default: []] += list } }
        return out
    }

    /// Runs a request after everything queued for the file's server, the latest edit included.
    func request<T: Sendable>(
        _ path: String, _ operation: @escaping @Sendable (LanguageSession, String) async -> T
    ) async -> T? {
        guard let (spec, _) = server(for: path), let uri = uri(for: path), let session = sessions[spec.id]
        else { return nil }
        flush(path)
        let previous = chains[spec.id]
        let task = Task {
            await previous?.value
            return await operation(session, uri)
        }
        chains[spec.id] = Task { _ = await task.value }
        return await task.value
    }

    private func locations(_ found: [Location]) -> [SymbolLocation] {
        found.compactMap { location in
            path(for: location.uri).map {
                SymbolLocation(
                    path: $0, start: (location.range.start.line, location.range.start.character),
                    end: (location.range.end.line, location.range.end.character))
            }
        }
    }

    public func saved(path: String) {
        guard let (spec, _) = server(for: path), let uri = uri(for: path), let session = sessions[spec.id]
        else { return }
        enqueue(spec.id) { await session.save(uri: uri) }
    }

    public func closed(path: String) {
        pendingChanges.removeValue(forKey: path)?.cancel()
        pendingTexts.removeValue(forKey: path)
        guard let (spec, _) = server(for: path), let uri = uri(for: path), let session = sessions[spec.id]
        else { return }
        enqueue(spec.id) { await session.close(uri: uri) }
    }

    /// A new path for a server (or none: the login PATH again): a running one stops, and the next file opened
    /// for it starts it from the new place.
    public func setOverride(_ specID: String, path: String?) {
        guard overrides[specID] != path else { return }
        overrides[specID] = path
        stop(specID)
    }

    /// The user's own servers changed: any added, removed or changed one stops, and the next file opened for
    /// it starts it as it is now.
    public func setCustom(_ specs: [ServerSpec]) {
        let ids = Set(custom.map(\.id)).union(specs.map(\.id))
        for id in ids where custom.first(where: { $0.id == id }) != specs.first(where: { $0.id == id }) { stop(id) }
        custom = specs
    }

    /// The server for a file — Forge's own first, then the user's — with the `languageId` to open it under.
    public func server(for path: String) -> (spec: ServerSpec, languageID: String)? {
        LanguageRegistry.server(for: path, among: LanguageRegistry.servers + custom)
    }

    private func stop(_ specID: String) {
        if let session = sessions.removeValue(forKey: specID) { Task { await session.shutdown() } }
        chains[specID] = nil
        statuses[specID] = nil
        progress[specID] = nil
        for (path, list) in issues where server(for: path)?.0.id == specID && !list.isEmpty { issues[path] = nil }
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
        case .triggers(let completion, let signature):
            completionTriggers[spec.id] = completion
            signatureTriggers[spec.id] = signature
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
            self.diagnostics[path] = diagnostics.isEmpty ? nil : diagnostics
        case .progress(let line):
            progress[spec.id] = line
        case .log(let line):
            let stamp = Date().formatted(date: .omitted, time: .standard)
            logs[spec.id] = (logs[spec.id] ?? []).suffix(499) + ["\(stamp)  \(line)"]
        case .applyEdit(let edit, let reply):
            let applied = onApplyEdit?(relative(edit.textChanges)) ?? false
            Task { await reply(applied) }
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

    func path(for uri: String) -> String? {
        guard let root, let url = URL(string: uri) else { return nil }
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let full = url.standardizedFileURL.resolvingSymlinksInPath().path
        return full.hasPrefix(base) ? String(full.dropFirst(base.count)) : nil
    }
}
