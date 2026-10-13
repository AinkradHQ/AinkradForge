import AppKit
import ForgeLanguage
import Foundation

/// A language server the user set up for a language Forge has none for (FP112, mockup 19 B): any stdio LSP,
/// run with its arguments under the same crash/restart policy as Forge's own. Its executable lives in
/// `EditorSettings.serverPaths[id]`, like a path override.
struct CustomServer: Codable, Equatable, Sendable {
    /// e.g. "Ruby".
    var language: String
    /// The LSP `languageId`, e.g. "ruby".
    var languageID: String
    /// The extensions it serves, e.g. ["rake", "rb"].
    var extensions: [String]
    var arguments: [String]

    var id: String { "custom-\(languageID)" }

    func spec(path: String?) -> ServerSpec {
        ServerSpec(
            id: id, language: language, command: path.map { ($0 as NSString).lastPathComponent } ?? languageID,
            arguments: arguments, languageIDs: Dictionary(uniqueKeysWithValues: extensions.map { ($0, languageID) }),
            installHint: "Set its path again.")
    }
}

extension ForgeModel {
    /// Set server path… (the bar's button, or `Language: Set Server Path…` at any width — FD48): asks for the
    /// executable of the server for the file at `path` — Forge's own where it has one, else a custom one.
    func chooseServerPath(forFileAt path: String) {
        if let (spec, _) = languages.server(for: path) {
            if let chosen = ServerPathPicker.choose(spec) { setServerPath(spec.id, chosen) }
        } else if let language = documents[path]?.language.name, let chosen = CustomServerPicker.choose(language: language) {
            setCustomServer(forFileAt: path, executable: chosen.path, arguments: chosen.arguments)
        }
    }

    /// Set server path… on a file whose language Forge has no server for: runs `executable arguments` for that
    /// language from now on (kept in settings), starting with the open files in it. Arguments split on spaces.
    func setCustomServer(forFileAt path: String, executable: String, arguments: String) {
        guard let document = documents[path] else { return }
        let ext = (path as NSString).pathExtension.lowercased()
        let server = CustomServer(
            language: document.language.name, languageID: document.language.id,
            extensions: document.language.extensions.union(ext.isEmpty ? [] : [ext]).sorted(),
            arguments: arguments.split(whereSeparator: \.isWhitespace).map(String.init))
        var settings = editorSettings
        settings.customServers.removeAll { $0.id == server.id }
        settings.customServers.append(server)
        settings.serverPaths[server.id] = (executable as NSString).expandingTildeInPath
        editorSettings = settings
        languages.setCustom(settings.customServers.map { $0.spec(path: settings.serverPaths[$0.id]) })
        // Starts it (or restarts it at the new path) with the open files it serves.
        setServerPath(server.id, executable)
    }

    /// Settings' Reset on a server set up here: the language goes back to having none.
    func removeCustomServer(_ id: String) {
        var settings = editorSettings
        settings.customServers.removeAll { $0.id == id }
        settings.serverPaths[id] = nil
        editorSettings = settings
        languages.setOverride(id, path: nil)
        languages.setCustom(settings.customServers.map { $0.spec(path: settings.serverPaths[$0.id]) })
    }
}

/// Asks for the executable and its arguments of a server for a language Forge has none for.
enum CustomServerPicker {
    @MainActor static func choose(language: String) -> (path: String, arguments: String)? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.message = "Choose a language server for \(language). It must speak LSP over stdin and stdout."
        panel.prompt = "Use"
        let arguments = NSTextField(string: "")
        arguments.placeholderString = "Arguments, e.g. stdio or --stdio"
        arguments.frame = NSRect(x: 0, y: 0, width: 360, height: 22)
        let row = NSStackView(views: [NSTextField(labelWithString: "Arguments:"), arguments])
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        panel.accessoryView = row
        panel.isAccessoryViewDisclosed = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return (url.path, arguments.stringValue)
    }
}
