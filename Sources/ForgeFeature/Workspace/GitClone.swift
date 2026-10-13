import Foundation
import Observation

/// Clone Repository… (mockup 05): a URL, the folder to clone into, then `git clone --progress` off the main
/// thread with its progress shown and Cancel. Credentials are git's own business — the user's credential helper
/// and SSH agent — so git is never allowed to prompt (`GIT_TERMINAL_PROMPT=0`, no stdin).
@MainActor
@Observable
final class GitClone {
    enum Phase: Equatable {
        case editing
        /// git's latest progress line, e.g. "Receiving objects", and its percentage when it gave one.
        case cloning(step: String, fraction: Double?)
        case failed(String)
    }

    var url = ""
    /// Where the clone's folder is made.
    var parent: URL
    var phase = Phase.editing
    /// Added to git's environment (tests stand in a slow transport).
    @ObservationIgnored var environment: [String: String] = [:]
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var cancelled = false

    init(parent: URL) {
        self.parent = parent
    }

    var trimmedURL: String { url.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The folder the clone lands in: `<parent>/<repo name>`.
    var destination: URL? { Self.repositoryName(trimmedURL).map { parent.appending(path: $0, directoryHint: .isDirectory) } }

    var isCloning: Bool { if case .cloning = phase { true } else { false } }

    /// `https://github.com/owner/repo.git`, `git@github.com:owner/repo`, `/path/to/repo.git` → `repo`.
    nonisolated static func repositoryName(_ url: String) -> String? {
        var tail = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while tail.hasSuffix("/") { tail.removeLast() }
        tail = String(tail.split(whereSeparator: { $0 == "/" || $0 == ":" }).last ?? "")
        if tail.hasSuffix(".git") { tail.removeLast(4) }
        return tail.isEmpty || tail == "." || tail == ".." ? nil : tail
    }

    /// Whether clipboard text is worth offering as the URL: a remote git understands, not any sentence.
    nonisolated static func looksLikeRepository(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return false }
        if ["https://", "http://", "ssh://", "git://", "file://"].contains(where: text.hasPrefix) { return true }
        // scp-like `user@host:path`.
        return text.range(of: #"^[\w.-]+@[\w.-]+:[\w./~-]+$"#, options: .regularExpression) != nil
    }

    /// git's progress (`Receiving objects:  42% (123/290)`), carriage-return separated → step and fraction.
    nonisolated static func progress(_ output: String) -> (step: String, fraction: Double?)? {
        let line = output.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).last.map(String.init) ?? ""
        let text = line.hasPrefix("remote: ") ? String(line.dropFirst(8)) : line
        guard let colon = text.firstIndex(of: ":") else { return text.isEmpty ? nil : (text, nil) }
        let step = String(text[..<colon])
        let percent = text.range(of: #"\d+(?=%)"#, options: .regularExpression).flatMap { Double(text[$0]) }
        return (step, percent.map { $0 / 100 })
    }

    /// Runs the clone; `done` gets the new folder once git exits 0.
    func start(done: @escaping @MainActor (URL) -> Void) {
        guard !isCloning, let destination else { return }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            phase = .failed("\(destination.lastPathComponent) already exists in \((parent.path as NSString).abbreviatingWithTildeInPath).")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["clone", "--progress", "--", trimmedURL, destination.path]
        process.currentDirectoryURL = parent
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
            .merging(["GIT_TERMINAL_PROMPT": "0"]) { $1 }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        // git's messages, kept for the error; read on the pipe's own queue, shown on the main actor.
        let log = CloneLog()
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = log.append(data)
            Task { @MainActor in
                guard let self, self.isCloning, let progress = Self.progress(text) else { return }
                self.phase = .cloning(step: progress.step, fraction: progress.fraction)
            }
        }
        // Holds the clone until git exits, so a dialog closed mid-clone still clears the half-made folder.
        process.terminationHandler = { finished in
            errors.fileHandleForReading.readabilityHandler = nil
            _ = log.append(errors.fileHandleForReading.readDataToEndOfFile())
            let status = finished.terminationStatus
            let message = log.failure
            Task { @MainActor in self.finished(status: status, message: message, destination: destination, done: done) }
        }
        cancelled = false
        phase = .cloning(step: "Starting", fraction: nil)
        do {
            try process.run()
            self.process = process
        } catch {
            phase = .failed("Could not run git: \(error.localizedDescription)")
        }
    }

    /// Stops a running clone; the half-made folder is removed when git has exited.
    func cancel() {
        guard isCloning else { return }
        cancelled = true
        process?.terminate()
    }

    private func finished(status: Int32, message: String, destination: URL, done: @MainActor (URL) -> Void) {
        process?.terminationHandler = nil
        process = nil
        if status == 0, !cancelled {
            phase = .editing
            return done(destination)
        }
        // Only ever our own folder: `start` refused a destination that already existed.
        try? FileManager.default.removeItem(at: destination)
        phase = cancelled ? .editing : .failed(message.isEmpty ? "git clone failed (exit \(status))." : message)
        cancelled = false
    }
}

/// git's stderr as it arrives, from the pipe's queue.
private final class CloneLog: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    /// Appends and returns the latest stretch (enough for the progress line).
    func append(_ data: Data) -> String {
        lock.withLock {
            text += String(decoding: data, as: UTF8.self)
            if text.count > 8_000 { text = String(text.suffix(4_000)) }
            return String(text.suffix(400))
        }
    }

    /// git's `fatal:` / `error:` lines, without its progress.
    var failure: String {
        lock.withLock {
            text.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).map(String.init)
                .filter { $0.hasPrefix("fatal: ") || $0.hasPrefix("error: ") || $0.hasPrefix("ERROR: ") }
                .map { $0.replacingOccurrences(of: "fatal: ", with: "") }
                .joined(separator: "\n")
        }
    }
}
