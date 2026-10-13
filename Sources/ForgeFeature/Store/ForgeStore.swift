import AinkradAppKit
import Foundation
import Observation

/// What Forge remembers, through the host's key→data store (`HostServices.documents`).
struct ForgeDocument: Codable, Equatable, Sendable {
    struct Recent: Codable, Equatable, Sendable {
        var path: String
        var opened: Date
    }

    /// Per workspace (keyed by its root path): the tabs and folders as they were left.
    struct WorkspaceState: Codable, Equatable, Sendable {
        var tabs = Tabs()
        var expanded: Set<String> = []
        /// Newest first, for ⌘P. Optional so state saved before it existed still decodes.
        var recentFiles: [String]?
        /// Split editor: every pane's tabs (`tabs` mirrors the first, for older readers), the focused one,
        /// and whether the panes stack top to bottom. Optional for the same reason.
        var panes: [Tabs]?
        var activePane: Int?
        var stacked: Bool?
    }

    /// Newest first.
    var recents: [Recent] = []
    /// Commands run from the palette, newest first (its "Recently used"). Optional so older state decodes.
    var recentCommands: [String]?
    var workspaces: [String: WorkspaceState] = [:]
    /// Reopened at launch, when it still exists.
    var lastWorkspace: String?
    /// Editor settings; nil = defaults. Optional so state saved before it existed still decodes.
    var editor: EditorSettings?
    /// Languages whose "no language server" hint was turned off for good ("Not for Ruby", E6).
    var quietLanguages: [String]?
}

/// The editor settings page. Decoded field by field, each falling back to its default, so a setting added
/// later never makes the saved ones unreadable.
struct EditorSettings: Codable, Equatable, Sendable {
    /// The mockups' 12.5 pt code face.
    var fontSize: Double = 12.5
    var tabWidth: Int = 4
    var insertSpaces = true
    var wrapLines = false
    var showMinimap = false
    var showInvisibles = false
    /// Language server id → the executable to run instead of the one on the login PATH.
    var serverPaths: [String: String] = [:]
    /// Servers the user set up for languages Forge has none for; each one's executable is in `serverPaths`.
    var customServers: [CustomServer] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = EditorSettings()
        fontSize = (try? c.decodeIfPresent(Double.self, forKey: .fontSize)) ?? d.fontSize
        tabWidth = (try? c.decodeIfPresent(Int.self, forKey: .tabWidth)) ?? d.tabWidth
        insertSpaces = (try? c.decodeIfPresent(Bool.self, forKey: .insertSpaces)) ?? d.insertSpaces
        wrapLines = (try? c.decodeIfPresent(Bool.self, forKey: .wrapLines)) ?? d.wrapLines
        showMinimap = (try? c.decodeIfPresent(Bool.self, forKey: .showMinimap)) ?? d.showMinimap
        showInvisibles = (try? c.decodeIfPresent(Bool.self, forKey: .showInvisibles)) ?? d.showInvisibles
        serverPaths = (try? c.decodeIfPresent([String: String].self, forKey: .serverPaths)) ?? d.serverPaths
        customServers = (try? c.decodeIfPresent([CustomServer].self, forKey: .customServers)) ?? d.customServers
    }
}

/// Loads `ForgeDocument` once and saves it on every change. Bytes that no longer decode are set aside,
/// never overwritten (see `loadDocument`).
@MainActor
@Observable
final class ForgeStore {
    static let key = "forge"
    static let recentLimit = 12

    private let documents: PluginDocumentStore
    private(set) var document: ForgeDocument
    private let canSave: Bool

    init(documents: PluginDocumentStore) {
        self.documents = documents
        let loaded = loadDocument(ForgeDocument.self, key: Self.key, from: documents)
        self.document = loaded.value ?? ForgeDocument()
        self.canSave = loaded.canSave
    }

    func update(_ change: (inout ForgeDocument) -> Void) {
        var copy = document
        change(&copy)
        guard copy != document else { return }
        document = copy
        guard canSave else { return }
        do {
            documents.setData(try JSONEncoder().encode(document), forKey: Self.key)
        } catch {
            Log.persistence.error("Forge state was not saved: \(error)")
        }
    }

    /// Unsaved buffers kept across a quit (hot exit): workspace root → path → text. Its own key, so the
    /// main state never carries file contents.
    static let unsavedKey = "forge.unsaved"

    func unsaved(in workspace: String) -> [String: String] {
        guard let data = documents.data(forKey: Self.unsavedKey),
            let all = try? JSONDecoder().decode([String: [String: String]].self, from: data)
        else { return [:] }
        return all[workspace] ?? [:]
    }

    func setUnsaved(_ buffers: [String: String], in workspace: String) {
        var all = documents.data(forKey: Self.unsavedKey)
            .flatMap { try? JSONDecoder().decode([String: [String: String]].self, from: $0) } ?? [:]
        all[workspace] = buffers.isEmpty ? nil : buffers
        documents.setData(all.isEmpty ? nil : try? JSONEncoder().encode(all), forKey: Self.unsavedKey)
    }

    /// Moves `path` to the top of the recents and makes it the workspace to reopen.
    func noteOpened(_ path: String, at date: Date = Date()) {
        update { doc in
            doc.recents.removeAll { $0.path == path }
            doc.recents.insert(.init(path: path, opened: date), at: 0)
            doc.recents = Array(doc.recents.prefix(Self.recentLimit))
            doc.lastWorkspace = path
        }
    }
}
