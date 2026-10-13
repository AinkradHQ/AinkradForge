import AppKit
import ForgeLanguage
import Foundation

/// The bar under a file's breadcrumb about its language server (E6): none for its language, the server is not
/// installed, or it stopped.
struct ServerBar: Equatable {
    enum Kind: Equatable {
        /// No server, or not installed: a gentle hint, closable, once per language.
        case missing
        /// Crashed twice in five minutes, or failed to start: red-washed, with Restart Server and Show Log.
        case stopped
    }

    let kind: Kind
    /// The language the hint is about, and its key for "Not for …".
    let language: String
    /// The server it is about, when Forge has one for the language.
    let spec: ServerSpec?
    let message: String
}

extension ForgeModel {
    /// The bar for `path`, if its server needs saying something about. Pure over the model's state, so tested.
    func serverBar(for path: String) -> ServerBar? {
        guard let document = documents[path], document.state == .ready else { return nil }
        guard let (spec, _) = LanguageRegistry.server(for: path) else {
            let language = document.language.name
            guard language != "Plaintext", !isQuiet(language) else { return nil }
            return ServerBar(
                kind: .missing, language: language, spec: nil,
                message: "No language server for \(language) — highlighting only; no completion, hover or go to definition.")
        }
        switch languages.statuses[spec.id] {
        case .notInstalled where !isQuiet(spec.language):
            // "Comes with Xcode." reads as is; a command is introduced.
            let install = spec.installHint.hasSuffix(".") ? spec.installHint : "Install it with \(spec.installHint)."
            return ServerBar(
                kind: .missing, language: spec.language, spec: spec,
                message: "\(spec.command) is not installed — highlighting only. \(install)")
        case .crashed(let how):
            return ServerBar(
                kind: .stopped, language: spec.language, spec: spec,
                message: "\(spec.command) stopped (\(how)) — twice in 5 minutes. Diagnostics and completion are paused.")
        case .failed(let why):
            return ServerBar(
                kind: .stopped, language: spec.language, spec: spec, message: "\(spec.command) could not start: \(why)")
        default:
            return nil
        }
    }

    private func isQuiet(_ language: String) -> Bool {
        dismissedHints.contains(language) || store.document.quietLanguages?.contains(language) == true
    }

    /// ✕ hides the hint for this session; "Not for …" (`forever`) never shows it again.
    func dismissServerHint(_ language: String, forever: Bool) {
        dismissedHints.insert(language)
        guard forever else { return }
        store.update { doc in
            if doc.quietLanguages?.contains(language) != true { doc.quietLanguages = (doc.quietLanguages ?? []) + [language] }
        }
    }

    /// Show Log: the server's log (its messages, when it started and stopped) in Console.
    func showServerLog(_ specID: String) {
        let url = FileManager.default.temporaryDirectory.appending(path: "forge-\(specID).log")
        do {
            try ((languages.logs[specID] ?? ["Nothing logged yet."]).joined(separator: "\n") + "\n")
                .write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.open(url)
        } catch {
            notice = "Could not write the server log: \(error.localizedDescription)"
        }
    }
}
