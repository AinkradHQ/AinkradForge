import Foundation

/// A language server Forge knows how to run, and the files it serves.
public struct ServerSpec: Identifiable, Equatable, Sendable {
    /// Stable key, also the settings key for a path override.
    public let id: String
    /// What the status menu calls the language.
    public let language: String
    /// Looked up on the login shell's PATH (or the override in settings).
    public let command: String
    public let arguments: [String]
    /// File extension → LSP `languageId`.
    public let languageIDs: [String: String]
    /// Where to point people when it is not installed.
    public let installHint: String
}

/// The servers Forge runs, one per language family. Pure, so the file → server mapping is tested.
public enum LanguageRegistry {
    public static let servers: [ServerSpec] = [
        ServerSpec(
            id: "sourcekit-lsp", language: "Swift", command: "sourcekit-lsp", arguments: [],
            languageIDs: ["swift": "swift", "m": "objective-c", "h": "c", "c": "c", "cpp": "cpp"],
            installHint: "Comes with Xcode."),
        ServerSpec(
            id: "typescript-language-server", language: "TypeScript", command: "typescript-language-server",
            arguments: ["--stdio"],
            languageIDs: ["ts": "typescript", "tsx": "typescriptreact", "js": "javascript", "jsx": "javascriptreact",
                          "mjs": "javascript", "cjs": "javascript"],
            installHint: "npm i -g typescript typescript-language-server"),
        ServerSpec(
            id: "intelephense", language: "PHP", command: "intelephense", arguments: ["--stdio"],
            languageIDs: ["php": "php"], installHint: "npm i -g intelephense"),
        ServerSpec(
            id: "gopls", language: "Go", command: "gopls", arguments: [], languageIDs: ["go": "go"],
            installHint: "go install golang.org/x/tools/gopls@latest"),
        ServerSpec(
            id: "pyright", language: "Python", command: "pyright-langserver", arguments: ["--stdio"],
            languageIDs: ["py": "python"], installHint: "npm i -g pyright"),
        // The three servers VS Code ships, packaged together as vscode-langservers-extracted.
        ServerSpec(
            id: "vscode-html-language-server", language: "HTML", command: "vscode-html-language-server",
            arguments: ["--stdio"], languageIDs: ["html": "html", "htm": "html"],
            installHint: "npm i -g vscode-langservers-extracted"),
        ServerSpec(
            id: "vscode-css-language-server", language: "CSS", command: "vscode-css-language-server",
            arguments: ["--stdio"], languageIDs: ["css": "css", "scss": "scss", "less": "less"],
            installHint: "npm i -g vscode-langservers-extracted"),
        ServerSpec(
            id: "vscode-json-language-server", language: "JSON", command: "vscode-json-language-server",
            arguments: ["--stdio"], languageIDs: ["json": "json", "jsonc": "jsonc"],
            installHint: "npm i -g vscode-langservers-extracted"),
        ServerSpec(
            id: "yaml-language-server", language: "YAML", command: "yaml-language-server", arguments: ["--stdio"],
            languageIDs: ["yaml": "yaml", "yml": "yaml"], installHint: "npm i -g yaml-language-server"),
    ]

    /// The server for a file, with the `languageId` to open it under; nil when no server serves it.
    public static func server(for path: String) -> (spec: ServerSpec, languageID: String)? {
        let ext = (path as NSString).pathExtension.lowercased()
        for spec in servers {
            if let id = spec.languageIDs[ext] { return (spec, id) }
        }
        return nil
    }
}
