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

    /// The executable for `command`: an absolute path as given, else the first match on the login PATH, then in
    /// the folders language toolchains install into without putting them on PATH (`go install` → ~/go/bin).
    static func locate(_ command: String) -> String? {
        if command.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: command) ? command : nil }
        let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let gopath = environment["GOPATH"].map { "\($0)/bin" }
        let folders = path.split(separator: ":").map(String.init)
            + [environment["GOBIN"], gopath, "\(home)/go/bin", "\(home)/.cargo/bin", "/opt/homebrew/bin", "/usr/local/bin"]
            .compactMap { $0 }
        return folders.map { "\($0)/\(command)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// One running language server for one workspace. An actor: LSP is stateful and order-sensitive, so the hub
/// chains calls one after another. Restarts once, silently, after a crash and re-opens every document the
/// server had; a second crash within five minutes leaves it stopped (`CrashPolicy`).
actor LanguageSession {
    enum Event: Sendable {
        case diagnostics(uri: String, [Diagnostic])
        case status(ServerStatus)
        /// Characters after which the server offers completions, and signature help.
        case triggers(completion: Set<String>, signature: Set<String>)
        /// The server asks Forge to make an edit (after a command it ran); `reply` says whether it was made.
        case applyEdit(WorkspaceEdit, reply: @Sendable (Bool) async -> Void)
        /// What the server is busy with ("Indexing 412 / 1280"), from `$/progress`; nil when idle.
        case progress(String?)
        /// A line for the server's log: its own log messages, and when it started and stopped.
        case log(String)
    }

    let spec: ServerSpec
    let root: URL
    let executable: String
    nonisolated let events: AsyncStream<Event>
    private let emit: AsyncStream<Event>.Continuation
    private var server: InitializingServer?
    private var eventLoop: Task<Void, Never>?
    private var documents: [String: (languageID: String, version: Int, text: String)] = [:]
    private var policy = CrashPolicy()
    private var progress = ProgressTracker()
    /// Bumped at every start, so the end of a process already replaced (a restart) is not taken for a crash.
    private var generation = 0
    private var process: Process?
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
        generation += 1
        let generation = generation
        process = nil
        do {
            let (channel, process) = try DataChannel.localProcessChannel(
                parameters: Process.ExecutionParameters(
                    path: executable, arguments: spec.arguments, environment: ShellEnvironment.environment,
                    currentDirectoryURL: root),
                terminationHandler: { [weak self] in Task { await self?.terminated(generation) } })
            self.process = process
            emit.yield(.log("Started \(executable) \(spec.arguments.joined(separator: " "))"))
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
                    switch event {
                    case .notification(.textDocumentPublishDiagnostics(let params)):
                        emit.yield(.diagnostics(uri: params.uri, params.diagnostics))
                    case .notification(.protocolProgress(let params)):
                        progressed(params)
                    case .notification(.windowLogMessage(let params)):
                        emit.yield(.log(params.message))
                    case .notification(.windowShowMessage(let params)):
                        emit.yield(.log(params.message))
                    case .request(_, let request):
                        await Self.answer(request, root: root, emit: emit)
                    default: break
                    }
                }
            }
            let reply = try await server.initializeIfNeeded()
            capabilities = reply.capabilities
            emit.yield(.triggers(
                completion: Set(reply.capabilities.completionProvider?.triggerCharacters ?? []),
                signature: Set(reply.capabilities.signatureHelpProvider?.triggerCharacters ?? [])))
            for (uri, document) in documents {
                try await server.textDocumentDidOpen(
                    DidOpenTextDocumentParams(textDocument: TextDocumentItem(
                        uri: uri, languageId: document.languageID, version: document.version, text: document.text)))
            }
            emit.yield(.status(.ready))
            emit.yield(.log("Ready"))
        } catch {
            // A process that died is `terminated`'s to report (as a crash); this is a live one failing, or none.
            // The pipe can close a moment before the process is reaped: give it that moment.
            if process?.isRunning == true { try? await Task.sleep(for: .milliseconds(300)) }
            guard generation == self.generation, process?.isRunning != false else { return }
            progress = ProgressTracker()
            emit.yield(.progress(nil))
            emit.yield(.log("Failed to start: \(error.localizedDescription)"))
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

    // MARK: - Requests (nil / empty when the server is down or does not know)

    /// The hover's contents as Markdown (code blocks fenced with their language).
    func hover(uri: String, line: Int, character: Int) async -> String? {
        guard let server, documents[uri] != nil,
            let hover = try? await server.hover(Self.position(uri, line, character))
        else { return nil }
        let text: String =
            switch hover.contents {
            case .optionA(let marked): Self.markdown(marked)
            case .optionB(let list): list.map(Self.markdown).joined(separator: "\n\n")
            case .optionC(let markup): markup.value
            }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    func definition(uri: String, line: Int, character: Int) async -> [Location] {
        guard let server, documents[uri] != nil,
            let reply = try? await server.definition(Self.position(uri, line, character))
        else { return [] }
        switch reply {
        case .optionA(let location): return [location]
        case .optionB(let locations): return locations
        case .optionC(let links): return links.map { Location(uri: $0.targetUri, range: $0.targetSelectionRange) }
        }
    }

    /// The file's outline, nested where the server nests it (a flat list from an older server).
    func documentSymbols(uri: String) async -> [DocumentSymbol] {
        guard let server, documents[uri] != nil,
            let reply = (try? await server.documentSymbol(DocumentSymbolParams(textDocument: TextDocumentIdentifier(uri: uri)))) ?? nil
        else { return [] }
        switch reply {
        case .optionA(let symbols): return symbols
        case .optionB(let flat):
            return flat.map { DocumentSymbol(name: $0.name, kind: $0.kind, range: $0.location.range, selectionRange: $0.location.range) }
        }
    }

    /// `workspace/symbol`: nil when the server does not offer it (a `WorkspaceSymbol` without a range is dropped).
    func workspaceSymbols(query: String) async -> [SymbolInformation]? {
        guard let server, let provider = capabilities?.workspaceSymbolProvider else { return nil }
        if case .optionA(false) = provider { return nil }
        switch (try? await server.workspaceSymbol(WorkspaceSymbolParams(query: query))) ?? nil {
        case .optionA(let found): return found
        case .optionB(let found):
            return found.compactMap { symbol in
                guard case .optionA(let location)? = symbol.location else { return nil }
                return SymbolInformation(name: symbol.name, kind: symbol.kind, location: location, containerName: symbol.containerName)
            }
        case nil: return []
        }
    }

    func references(uri: String, line: Int, character: Int) async -> [Location] {
        guard let server, documents[uri] != nil else { return [] }
        let params = ReferenceParams(
            textDocument: TextDocumentIdentifier(uri: uri), position: Position(line: line, character: character),
            includeDeclaration: true)
        return (try? await server.references(params)) ?? []
    }

    func completions(uri: String, line: Int, character: Int) async -> [CompletionItem] {
        guard let server, documents[uri] != nil else { return [] }
        let params = CompletionParams(
            textDocument: TextDocumentIdentifier(uri: uri), position: Position(line: line, character: character),
            context: nil)
        switch (try? await server.completion(params)) ?? nil {
        case .optionA(let items): return items
        case .optionB(let list): return list.items
        case nil: return []
        }
    }

    func signatureHelp(uri: String, line: Int, character: Int) async -> SignatureHelp? {
        guard let server, documents[uri] != nil else { return nil }
        return (try? await server.signatureHelp(Self.position(uri, line, character))) ?? nil
    }

    func rename(uri: String, line: Int, character: Int, to newName: String) async -> WorkspaceEdit? {
        guard let server, documents[uri] != nil else { return nil }
        let params = RenameParams(
            textDocument: TextDocumentIdentifier(uri: uri), position: Position(line: line, character: character),
            newName: newName)
        return (try? await server.rename(params)) ?? nil
    }

    func codeActions(uri: String, range: LSPRange, diagnostics: [Diagnostic]) async -> [TwoTypeOption<Command, CodeAction>] {
        guard let server, documents[uri] != nil else { return [] }
        let params = CodeActionParams(
            textDocument: TextDocumentIdentifier(uri: uri), range: range,
            context: CodeActionContext(diagnostics: diagnostics, only: nil))
        return ((try? await server.codeAction(params)) ?? nil) ?? []
    }

    func execute(_ command: Command) async {
        _ = try? await server?.executeCommand(ExecuteCommandParams(command: command.command, arguments: command.arguments))
    }

    func format(uri: String, tabSize: Int, insertSpaces: Bool) async -> [TextEdit] {
        guard let server, documents[uri] != nil else { return [] }
        let params = DocumentFormattingParams(
            textDocument: TextDocumentIdentifier(uri: uri), options: FormattingOptions(tabSize: tabSize, insertSpaces: insertSpaces))
        return ((try? await server.formatting(params)) ?? nil) ?? []
    }

    /// Every request a server can send must be answered, or the server may wait on it forever (pyright and
    /// intelephense ask for their configuration at start). Edits go to the hub; the rest get neutral answers.
    private static func answer(_ request: ServerRequest, root: URL, emit: AsyncStream<Event>.Continuation) async {
        switch request {
        case .workspaceApplyEdit(let params, let handler):
            let (stream, done) = AsyncStream<Bool>.makeStream()
            emit.yield(.applyEdit(params.edit, reply: { applied in
                done.yield(applied)
                done.finish()
            }))
            var applied = false
            for await result in stream { applied = result }
            await handler(.success(ApplyWorkspaceEditResult(applied: applied)))
        case .workspaceConfiguration(let params, let handler):
            await handler(.success(params.items.map { _ in LSPAny.null }))
        case .workspaceFolders(let handler):
            await handler(.success([WorkspaceFolder(uri: root.absoluteString, name: root.lastPathComponent)]))
        case .clientRegisterCapability(_, let handler), .clientUnregisterCapability(_, let handler),
            .workspaceCodeLensRefresh(let handler), .workspaceSemanticTokenRefresh(let handler),
            .windowWorkDoneProgressCreate(_, let handler):
            await handler(nil)
        case .windowShowMessageRequest(_, let handler):
            await handler(.success(nil))
        case .windowShowDocument(_, let handler):
            await handler(.success(ShowDocumentResult(success: false)))
        case .custom(_, _, let handler):
            await handler(.success(LSPAny.null))
        }
    }

    private static func position(_ uri: String, _ line: Int, _ character: Int) -> TextDocumentPositionParams {
        TextDocumentPositionParams(
            textDocument: TextDocumentIdentifier(uri: uri), position: Position(line: line, character: character))
    }

    private static func markdown(_ marked: MarkedString) -> String {
        switch marked {
        case .optionA(let text): text
        case .optionB(let pair): "```\(pair.language)\n\(pair.value)\n```"
        }
    }

    /// Ends the server (closing the workspace, or a manual restart).
    func shutdown() async {
        isShuttingDown = true
        eventLoop?.cancel()
        try? await server?.shutdownAndExit()
        server = nil
        progress = ProgressTracker()
        emit.yield(.progress(nil))
        emit.yield(.status(.notRunning))
    }

    /// Restart on request (the status menu): a clean stop, then a start that re-opens every document.
    func restart() async {
        await shutdown()
        isShuttingDown = false
        policy.reset()
        await start()
    }

    private func progressed(_ params: ProgressParams) {
        let line = progress.update(token: ProgressTracker.key(params.token), value: params.value)
        emit.yield(.progress(line))
    }

    /// The process ended without being asked to: restart it once, silently; a second time within five minutes,
    /// stop and say how it ended.
    private func terminated(_ ended: Int) async {
        guard ended == generation, !isShuttingDown else { return }
        server = nil
        progress = ProgressTracker()
        emit.yield(.progress(nil))
        let how = process.map { CrashPolicy.describe(status: $0.terminationStatus, bySignal: $0.terminationReason == .uncaughtSignal) } ?? "exit"
        emit.yield(.log("Stopped: \(how)"))
        guard policy.crashed(at: Date()) else {
            emit.yield(.status(.crashed(how)))
            return
        }
        emit.yield(.status(.starting))
        try? await Task.sleep(for: .seconds(1))
        guard ended == generation, !isShuttingDown else { return }
        await start()
    }

    /// What Forge can show today; widened as hover, completion and the rest land.
    static let clientCapabilities = ClientCapabilities(
        workspace: ClientCapabilities.Workspace(
            applyEdit: true, workspaceEdit: nil, didChangeConfiguration: nil, didChangeWatchedFiles: nil, symbol: nil,
            executeCommand: nil, workspaceFolders: true, configuration: true, semanticTokens: nil),
        textDocument: TextDocumentClientCapabilities(
            synchronization: TextDocumentSyncClientCapabilities(
                dynamicRegistration: false, willSave: false, willSaveWaitUntil: false, didSave: true),
            completion: CompletionClientCapabilities(
                dynamicRegistration: false,
                completionItem: CompletionClientCapabilities.CompletionItem(
                    snippetSupport: true, documentationFormat: [.markdown, .plaintext], deprecatedSupport: true)),
            hover: HoverClientCapabilities(dynamicRegistration: false, contentFormat: [.markdown, .plaintext]),
            signatureHelp: SignatureHelpClientCapabilities(
                dynamicRegistration: false,
                signatureInformation: SignatureHelpClientCapabilities.SignatureInformation(
                    documentationFormat: [.markdown, .plaintext], labelOffsetSupport: true, activeParameterSupport: true),
                contextSupport: false),
            definition: DynamicRegistrationLinkSupportClientCapabilities(dynamicRegistration: false, linkSupport: true),
            references: DynamicRegistrationClientCapabilities(dynamicRegistration: false),
            documentSymbol: DocumentSymbolClientCapabilities(dynamicRegistration: false, hierarchicalDocumentSymbolSupport: true),
            codeAction: CodeActionClientCapabilities(
                dynamicRegistration: false,
                codeActionLiteralSupport: CodeActionClientCapabilities.CodeActionLiteralSupport(
                    codeActionKind: ValueSet(valueSet: ["quickfix", "refactor", "source"])),
                isPreferredSupport: true),
            formatting: DocumentFormattingClientCapabilities(dynamicRegistration: false),
            rename: RenameClientCapabilities(
                dynamicRegistration: false, prepareSupport: false, prepareSupportDefaultBehavior: nil,
                honorsChangeAnnotations: false),
            publishDiagnostics: PublishDiagnosticsClientCapabilities(
                relatedInformation: false, tagSupport: nil, versionSupport: false, codeDescriptionSupport: false,
                dataSupport: false)),
        window: WindowClientCapabilities(workDoneProgress: true, showMessage: nil, showDocument: nil), general: nil,
        experimental: nil)
}

/// A server's state, for the status bar and its menu.
@frozen public enum ServerStatus: Equatable, Sendable {
    case notInstalled
    case notRunning
    case starting
    case ready
    case failed(String)
    /// Stopped twice within five minutes; how it last ended ("signal 11 (SEGV)"). Restarts only when asked.
    case crashed(String)
}
