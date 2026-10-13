import AinkradAppKit
import AppKit
import ForgeLanguage
import Foundation

/// A request to an agent about some code: where it is, and what to do.
struct AskRequest: Equatable {
    let pane: Int
    let path: String
    let rect: CGRect
    /// 1-based, inclusive.
    let lines: ClosedRange<Int>
    let code: String
    var prompt = ""

    /// The launch payload Grimoire reads (its `AskLaunch`): the project folder and the request.
    func payload(root: URL) -> String? {
        let body = ["kind": "askAgent", "path": root.path(percentEncoded: false), "prompt": message]
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) }
    }

    /// What goes to the agent: the place, the code, the words.
    var message: String {
        let place = lines.count == 1 ? "line \(lines.lowerBound)" : "lines \(lines.lowerBound)–\(lines.upperBound)"
        let fence = (path as NSString).pathExtension
        return "In \(path), \(place):\n\n```\(fence)\n\(code)\n```\n\n\(prompt)"
    }
}

/// ⌘I: ask an agent (Grimoire) about the selection.
extension ForgeModel {
    func beginAsk() {
        guard let path = tabs.active, let document = documents[path], document.state == .ready else { return }
        let text = document.storage.string as NSString
        // The selection's whole lines; with nothing selected, the caret's line. Clamped by hand: NSIntersectionRange
        // answers {0, 0} for a caret at the very end, which asked about line 1 from the last line (E0 FD9).
        let location = min(document.selection.location, text.length)
        let range = text.lineRange(for: NSRange(location: location, length: min(document.selection.length, text.length - location)))
        let index = LineIndex(document.storage.string)
        let first = index.position(of: range.location).line + 1
        let last = max(first, index.position(of: max(range.location, NSMaxRange(range) - 1)).line + 1)
        let code = text.substring(with: range).trimmingCharacters(in: .newlines)
        agent.ask = AskRequest(pane: activePane, path: path, rect: document.caretRect, lines: first...last, code: code)
    }

    /// Ask: Grimoire opens a new thread on this workspace with the request (to start once the agent is chosen).
    /// The request also goes on the clipboard, for a Grimoire too old to read it.
    func sendAsk() {
        guard let request = agent.ask, !request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        agent.ask = nil
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(request.message, forType: .string)
        guard let apps, let root = workspace?.root else { return }
        let payload = request.payload(root: root)
        guard let reporting = apps as? PluginAppLauncherResult else {
            apps.open(appID: Self.grimoireAppID, payload: payload)
            return notice = "Grimoire opens a new thread with the request — choose the agent and start it."
        }
        switch reporting.openReportingOutcome(appID: Self.grimoireAppID, payload: payload) {
        case .opened: notice = "Grimoire opens a new thread with the request — choose the agent and start it."
        case .unknownApp: notice = "The request is on the clipboard. Install Grimoire from the Ainkrad store to ask an agent here."
        case .disabled: notice = "The request is on the clipboard. Grimoire is turned off — enable it in Ainkrad."
        case .refused(let reason): notice = "The request is on the clipboard. Grimoire didn't open: \(reason)"
        @unknown default: notice = "The request is on the clipboard."
        }
    }

    static let grimoireAppID = "grimoire"
}
