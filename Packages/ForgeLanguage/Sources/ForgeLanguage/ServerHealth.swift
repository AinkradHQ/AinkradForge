import Foundation
internal import LanguageServerProtocol

/// When a crashed server comes back by itself: the first crash in five minutes restarts it silently; a second
/// within that window stops it and says so (E6). Pure, so the policy is tested.
struct CrashPolicy {
    static let window: TimeInterval = 300
    private(set) var crashes: [Date] = []

    /// Notes a crash at `now`; true when the server should restart silently.
    mutating func crashed(at now: Date) -> Bool {
        crashes = crashes.filter { now.timeIntervalSince($0) < Self.window } + [now]
        return crashes.count < 2
    }

    mutating func reset() { crashes = [] }

    /// How a server process ended, as the crash bar says it: "exit 3", "signal 11 (SEGV)".
    static func describe(status: Int32, bySignal: Bool) -> String {
        guard bySignal else { return "exit \(status)" }
        let names = ["HUP", "INT", "QUIT", "ILL", "TRAP", "ABRT", "EMT", "FPE", "KILL", "BUS", "SEGV", "SYS", "PIPE", "ALRM", "TERM"]
        return names.indices.contains(Int(status) - 1) ? "signal \(status) (\(names[Int(status) - 1]))" : "signal \(status)"
    }
}

/// The server's `$/progress` reports, folded into one line for the status bar: "Indexing 412 / 1280".
/// The newest unfinished task wins; nil once every task has ended.
struct ProgressTracker {
    private var tasks: [(token: String, title: String, detail: String?)] = []

    /// Folds in one `$/progress` value (a WorkDoneProgress begin / report / end); returns the line to show.
    mutating func update(token: String, value: LSPAny?) -> String? {
        guard case .hash(let fields) = value, case .string(let kind) = fields["kind"] else { return line }
        let message: String? = if case .string(let text) = fields["message"], !text.isEmpty { text } else { nil }
        let percent: String? = if case .number(let value) = fields["percentage"] { "\(Int(value))%" } else { nil }
        switch kind {
        case "begin":
            let title: String = if case .string(let text) = fields["title"] { text } else { "Working" }
            tasks.removeAll { $0.token == token }
            tasks.append((token, title, message ?? percent))
        case "report":
            if let index = tasks.firstIndex(where: { $0.token == token }) { tasks[index].detail = message ?? percent ?? tasks[index].detail }
        case "end":
            tasks.removeAll { $0.token == token }
        default: break
        }
        return line
    }

    var line: String? { tasks.last.map { task in [task.title, task.detail].compactMap { $0 }.joined(separator: " ") } }

    static func key(_ token: ProgressToken) -> String {
        switch token {
        case .optionA(let number): "\(number)"
        case .optionB(let text): text
        }
    }
}
