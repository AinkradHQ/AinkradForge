import Foundation
import Testing

@testable import ForgeFeature

@MainActor
@Suite("Server paths")
struct ServerPathTests {
    @Test func aPathIsKeptExpandedAndEmptyMeansThePath() {
        let model = ForgeModel(store: ForgeStore(documents: MemoryDocs()))
        model.setServerPath("gopls", "  ~/go/bin/gopls ")
        #expect(model.editorSettings.serverPaths["gopls"] == NSHomeDirectory() + "/go/bin/gopls")
        #expect(model.languages.overrides["gopls"] == NSHomeDirectory() + "/go/bin/gopls")
        model.setServerPath("gopls", "")
        #expect(model.editorSettings.serverPaths["gopls"] == nil)
        #expect(model.languages.overrides["gopls"] == nil)
    }
}
