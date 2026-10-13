import AinkradAppKit
import AppKit
import ForgeLanguage
import SwiftUI
import XCTest

@testable import ForgeFeature

/// Goldens for the mockup features built after design parity (quick open's symbol modes, the palette's rebind,
/// splits, the split terminal), drawn as `SnapshotTests` draws — see there for what keeps a shot stable.
@MainActor
final class MockupFeatureSnapshotTests: XCTestCase {
    private var repo: URL!

    override func setUp() async throws {
        repo = try SampleRepo.make()
    }

    override func tearDown() async throws {
        if let repo { try? FileManager.default.removeItem(at: repo.deletingLastPathComponent()) }
    }

    /// `SidebarRow.swift`'s outline as sourcekit-lsp gives it (0-based lines).
    static let sidebarSymbols = ([
        ("SidebarRow", "struct", 4, nil), ("skin", "property", 5, "SidebarRow"), ("thread", "property", 6, "SidebarRow"),
        ("isSelected", "property", 7, "SidebarRow"), ("body", "property", 9, "SidebarRow"),
    ] as [(String, String, Int, String?)]).map { name, kind, line, container in
        SymbolEntry(name: name, kind: kind, path: SnapshotTests.sidebarRow, line: line, character: 4, container: container)
    }

    /// The window with `SidebarRow.swift` open, its symbols standing in for the server's.
    private func window() throws -> ForgeModel {
        let model = try Snapshot.model(opening: repo)
        Snapshot.expandSidebar(model)
        model.open(file: SnapshotTests.sidebarRow, pinned: true)
        try SweepSupport.waitUntilLoaded(model)
        model.symbolSource = { _, _, _ in PaletteSymbols(entries: Self.sidebarSymbols) }
        return model
    }

    /// ⌘P `@`: the file's symbols, kind first, its file and line after (mockup 02's symbol rows).
    func testQuickOpenSymbols() throws {
        let model = try window()
        model.palette = "@"
        try Snapshot.assertMatches(model, named: "quick-open-symbols")
    }

    /// ⌘P "sbrow": the files, then "Symbols · type @ to search only symbols" (mockup 02).
    func testQuickOpenWithSymbols() throws {
        let model = try window()
        model.palette = "sbrow"
        try Snapshot.assertMatches(model, named: "quick-open-files-symbols")
    }
}
