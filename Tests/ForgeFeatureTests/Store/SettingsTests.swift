import AinkradAppKit
import Foundation
import Testing

@testable import ForgeFeature

@MainActor
@Suite("Editor settings")
struct SettingsTests {
    /// A setting added later must not make the saved ones unreadable: missing keys take their defaults.
    @Test func settingsDecodeFieldByField() throws {
        let partial = try JSONDecoder().decode(EditorSettings.self, from: Data(#"{"fontSize":16,"wrapLines":true}"#.utf8))
        #expect(partial.fontSize == 16 && partial.wrapLines)
        #expect(partial.tabWidth == 4 && partial.insertSpaces && !partial.showMinimap)
    }

    @Test func theSettingsPageWritesThroughAndPersists() throws {
        let docs = MemoryDocs()
        let host = FakeHost(docs: docs)
        let page = try #require(ForgeApp.settingsCatalog(host: host))
        let fields = page.groups.flatMap(\.fields)
        #expect(fields.count == 6)
        guard case .toggle(let wrap) = try #require(fields.first { $0.label == "Wrap lines" }).kind else {
            Issue.record("Wrap lines is not a toggle"); return
        }
        wrap.wrappedValue = true
        #expect(ForgeStore(documents: docs).document.editor?.wrapLines == true)
        guard case .slider(_, _, let size) = try #require(fields.first { $0.label == "Font size" }).kind else {
            Issue.record("Font size is not a slider"); return
        }
        size.wrappedValue = 18
        #expect(ForgeStore(documents: docs).document.editor?.fontSize == 18)
    }
}
