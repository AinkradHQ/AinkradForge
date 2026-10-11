import Foundation
import Testing

@testable import ForgeLanguage

/// E5.4: each server against a real repository — status, issues, hover and definition on the first type a
/// file declares. A tool, not a check: it runs only with FORGE_STACK_CHECK set to `root|file;root|file…`, and
/// prints what it found (a missing server is reported, not failed).
@MainActor
@Suite("Stack check")
struct StackCheckTests {
    @Test func everyStackAnswers() async throws {
        guard let spec = ProcessInfo.processInfo.environment["FORGE_STACK_CHECK"] else { return }
        for pair in spec.split(separator: ";") {
            let parts = pair.split(separator: "|").map(String.init)
            guard parts.count == 2 else { continue }
            print(await check(root: URL(fileURLWithPath: parts[0]), file: parts[1]))
        }
    }

    private func check(root: URL, file: String) async -> String {
        guard let text = try? String(contentsOf: root.appending(path: file), encoding: .utf8),
            let (spec, _) = LanguageRegistry.server(for: file)
        else { return "STACK \(file): unreadable or no server" }
        let hub = LanguageHub()
        hub.begin(root: root)
        defer { hub.end() }
        hub.opened(path: file, text: text)
        let started = ContinuousClock.now
        for _ in 0..<600 where ![.ready, .notInstalled].contains(hub.statuses[spec.id]) && !isFailed(hub.statuses[spec.id]) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let status = hub.statuses[spec.id].map { "\($0)" } ?? "none"
        guard hub.statuses[spec.id] == .ready else { return "STACK \(spec.command) \(file): \(status)" }
        let ready = ContinuousClock.now - started
        // The first declared type: `struct|class|enum|interface|type|func|def Name`.
        var line = 0
        var character = 0
        for (index, row) in text.components(separatedBy: "\n").enumerated() {
            if let range = row.range(of: #"\b(struct|class|enum|interface|protocol|func|def|type)\s+[A-Za-z_]"#, options: .regularExpression) {
                line = index
                character = row.utf16.distance(from: row.utf16.startIndex, to: range.upperBound.samePosition(in: row.utf16) ?? row.utf16.endIndex) - 1
                break
            }
        }
        var hover: String?
        for _ in 0..<30 where hover == nil {
            hover = await hub.hover(path: file, line: line, character: character)
            if hover == nil { try? await Task.sleep(for: .milliseconds(500)) }
        }
        let definitions = await hub.definition(path: file, line: line, character: character)
        try? await Task.sleep(for: .seconds(3))
        let issues = hub.issues[file]?.count ?? 0
        let firstHover = hover?.split(separator: "\n").first { !$0.hasPrefix("```") }.map(String.init) ?? "—"
        return "STACK \(spec.command) \(file): ready in \(ready) · hover@\(line + 1):\(character + 1) \(hover == nil ? "NONE" : "“\(firstHover.prefix(60))”") · definitions \(definitions.count) · issues \(issues)"
    }

    private func isFailed(_ status: ServerStatus?) -> Bool {
        if case .failed = status { true } else { false }
    }
}
