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
    var workspaces: [String: WorkspaceState] = [:]
    /// Reopened at launch, when it still exists.
    var lastWorkspace: String?
    /// Editor settings; nil = defaults. Optional so state saved before it existed still decodes.
    var editor: EditorSettings?
}

/// The editor settings page. Decoded field by field, each falling back to its default, so a setting added
/// later never makes the saved ones unreadable.
struct EditorSettings: Codable, Equatable, Sendable {
    var fontSize: Double = 13
    var tabWidth: Int = 4
    var insertSpaces = true
    var wrapLines = false
    var showMinimap = false
    var showInvisibles = false

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
