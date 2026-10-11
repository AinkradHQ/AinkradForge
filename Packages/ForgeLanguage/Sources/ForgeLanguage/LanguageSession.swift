import Foundation
internal import JSONRPC
internal import LanguageClient
internal import LanguageServerProtocol
internal import ProcessEnv

/// The user's login-shell environment, captured once. A GUI app does not inherit the shell's PATH, so without
/// this `gopls`, `intelephense` and friends are never found.
enum ShellEnvironment {
    private static let captured: [String: String] = {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        let out = Pipe()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "env -0"]
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return ProcessInfo.processInfo.environment }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var env: [String: String] = [:]
        for entry in data.split(separator: 0) {
            guard let line = String(data: entry, encoding: .utf8), let eq = line.firstIndex(of: "=") else { continue }
            env[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        return env.isEmpty ? ProcessInfo.processInfo.environment : env
    }()

    static var environment: [String: String] { captured }

    /// The executable for `command`: an absolute path as given, else the first match on the login PATH.
    static func locate(_ command: String) -> String? {
        if command.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: command) ? command : nil }
        let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
        return path.split(separator: ":").map { "\($0)/\(command)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// One running language server for one workspace. An actor: LSP is stateful and order-sensitive, so the hub
/// chains calls one after another. Restarts after a crash (with backoff, at most 3 times in 2 minutes) and
/// re-opens every document the server had.
actor LanguageSession {
    enum Event: Sendable {
        case diagnostics(uri: String, [Diagnostic])
        case status(ServerStatus)
    }

    let spec: ServerSpec
    let root: URL
    let executable: String
    nonisolated let events: AsyncStream<Event>
    private let emit: AsyncStream<Event>.Continuation
    private var server: InitializingServer?
    private var eventLoop: Task<Void, Never>?
    private var documents: [String: (languageID: String, version: Int, text: String)] = [:]
    private var crashes: [Date] = []
    private var isShuttingDown = false
    private(set) var capabilities: ServerCapabilities?

    init(spec: ServerSpec, root: URL, executable: String) {
        self.spec = spec
        self.root = root
        self.executable = executable
        (events, emit) = AsyncStream.makeStream()
    }

    /// Starts the process and does the initialize handshake.
    func start() async {
        emit.yield(.status(.starting))
        do {
            let channel: DataChannel = try DataChannel.localProcessChannel(
                parameters: Process.ExecutionParameters(
                    path: executable, arguments: spec.arguments, environment: ShellEnvironment.environment,
                    currentDirectoryURL: root),
                terminationHandler: { [weak self] in Task { await self?.terminated() } })
            let root = root
            let server = InitializingServer(server: JSONRPCServerConnection(dataChannel: channel)) {
                InitializeParams(
                    processId: Int(ProcessInfo.processInfo.processIdentifier), locale: nil, rootPath: root.path,
                    rootUri: root.absoluteString, initializationOptions: nil, capabilities: Self.clientCapabilities,
                    trace: nil, workspaceFolders: [WorkspaceFolder(uri: root.absoluteString, name: root.lastPathComponent)])
            }
            self.server = server
            eventLoop?.cancel()
            let emit = emit
            eventLoop = Task {
                for await event in server.eventSequence {
                    if case .notification(.textDocumentPublishDiagnostics(let params)) = event {
                        emit.yield(.diagnostics(uri: params.uri, params.diagnostics))
                    }
                }
            }
            let reply = try await server.initializeIfNeeded()
            capabilities = reply.capabilities
            for (uri, document) in documents {
                try await server.textDocumentDidOpen(
                    DidOpenTextDocumentParams(textDocument: TextDocumentItem(
                        uri: uri, languageId: document.languageID, version: document.version, text: document.text)))
            }
            emit.yield(.status(.ready))
        } catch {
            emit.yield(.status(.failed(error.localizedDescription)))
        }
    }

    func open(uri: String, languageID: String, text: String) async {
        documents[uri] = (languageID, 1, text)
        try? await server?.textDocumentDidOpen(
            DidOpenTextDocumentParams(textDocument: TextDocumentItem(uri: uri, languageId: languageID, version: 1, text: text)))
    }

    /// Full-document sync: every change sends the whole text (every server supports it; edits are debounced).
    func change(uri: String, text: String) async {
        guard var document = documents[uri] else { return }
        document.version += 1
        document.text = text
        documents[uri] = document
        try? await server?.textDocumentDidChange(
            DidChangeTextDocumentParams(
                textDocument: VersionedTextDocumentIdentifier(uri: uri, version: document.version),
                contentChanges: [TextDocumentContentChangeEvent(range: nil, rangeLength: nil, text: text)]))
    }

    func save(uri: String) async {
        guard documents[uri] != nil else { return }
        try? await server?.textDocumentDidSave(DidSaveTextDocumentParams(textDocument: TextDocumentIdentifier(uri: uri), text: nil))
    }

    func close(uri: String) async {
        guard documents.removeValue(forKey: uri) != nil else { return }
        try? await server?.textDocumentDidClose(DidCloseTextDocumentParams(textDocument: TextDocumentIdentifier(uri: uri)))
        emit.yield(.diagnostics(uri: uri, []))
    }

    var openDocumentCount: Int { documents.count }

    /// Ends the server (closing the workspace, or a manual restart).
    func shutdown() async {
        isShuttingDown = true
        eventLoop?.cancel()
        try? await server?.shutdownAndExit()
        server = nil
        emit.yield(.status(.notRunning))
    }

    /// Restart on request (the status menu): a clean stop, then a start that re-opens every document.
    func restart() async {
        await shutdown()
        isShuttingDown = false
        crashes = []
        await start()
    }

    private func terminated() async {
        guard !isShuttingDown else { return }
        server = nil
        let now = Date()
        crashes = crashes.filter { now.timeIntervalSince($0) < 120 } + [now]
        guard crashes.count <= 3 else {
            emit.yield(.status(.failed("\(spec.command) stopped 3 times in 2 minutes. Restart it from the status bar.")))
            return
        }
        emit.yield(.status(.starting))
        try? await Task.sleep(for: .seconds(Double(crashes.count)))
        await start()
    }

    /// What Forge can show today; widened as hover, completion and the rest land.
    static let clientCapabilities = ClientCapabilities(
        workspace: nil,
        textDocument: TextDocumentClientCapabilities(
            synchronization: TextDocumentSyncClientCapabilities(
                dynamicRegistration: false, willSave: false, willSaveWaitUntil: false, didSave: true),
            publishDiagnostics: PublishDiagnosticsClientCapabilities(
                relatedInformation: false, tagSupport: nil, versionSupport: false, codeDescriptionSupport: false,
                dataSupport: false)),
        window: nil, general: nil, experimental: nil)
}

/// A server's state, for the status bar and its menu.
@frozen public enum ServerStatus: Equatable, Sendable {
    case notInstalled
    case notRunning
    case starting
    case ready
    case failed(String)
}
