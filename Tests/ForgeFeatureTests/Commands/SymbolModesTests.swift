import ForgeLanguage
import Foundation
import Testing

@testable import ForgeFeature

/// Quick open's `@` / `#` symbol modes and ⌘↵ / ⌥↵ (mockup 02).
@MainActor
@Suite("Quick open symbols")
struct SymbolModesTests {
    static let symbols = [
        SymbolEntry(name: "SidebarRow", kind: "struct", path: "Sources/SidebarRow.swift", line: 4, character: 7, container: nil),
        SymbolEntry(name: "body", kind: "property", path: "Sources/SidebarRow.swift", line: 9, character: 8, container: "SidebarRow"),
        SymbolEntry(name: "isSelected", kind: "property", path: "Sources/SidebarRow.swift", line: 6, character: 8, container: "SidebarRow"),
    ]

    @Test func atAndHashAreModes() {
        #expect(Palette.split("@body") == ("@", "body"))
        #expect(Palette.split("#Row") == ("#", "Row"))
    }

    /// `@`: the file's symbols ranked by the query, each with its kind (leading the row) and its matched letters.
    @Test func atRanksThisFilesSymbols() {
        let model = ForgeModel(store: ForgeStore(documents: MemoryDocs()))
        model.paletteSymbols = PaletteSymbols(entries: Self.symbols)
        let all = Palette.items(for: "@", model: model)
        #expect(all.map(\.title) == ["SidebarRow", "body", "isSelected"])
        #expect(all.map(\.kind) == ["struct", "property", "property"])
        let hits = Palette.items(for: "@sel", model: model)
        #expect(hits.map(\.title) == ["isSelected"])
        #expect(hits.first?.detail == "SidebarRow.swift:7")
        #expect(hits.first?.payload == .symbol(path: "Sources/SidebarRow.swift", line: 7))
        // `s`, `e`, `l` of isSelected.
        #expect(hits.first?.matched == [2, 3, 4])
    }

    /// `#`: the server already matched, so its rows are kept as they came.
    @Test func hashKeepsTheServersMatches() {
        let model = ForgeModel(store: ForgeStore(documents: MemoryDocs()))
        model.paletteSymbols = PaletteSymbols(entries: Self.symbols)
        #expect(Palette.items(for: "#zz", model: model).isEmpty)
        model.paletteSymbols.scope = "#"
        #expect(Palette.items(for: "#zz", model: model).count == 3)
        #expect(Palette.items(for: "@", model: model).isEmpty)
    }

    @Test func symbolsComeFromTheSourceAndTellWhyThereAreNone() async {
        let model = ForgeModel(store: ForgeStore(documents: MemoryDocs()))
        await model.loadPaletteSymbols(for: "@")
        #expect(model.paletteSymbols.note == "Open a file to go to its symbols.")
        await model.loadPaletteSymbols(for: "#")
        #expect(model.paletteSymbols.note == "Type a symbol's name to search the workspace.")
        await model.loadPaletteSymbols(for: "#Row")
        #expect(model.paletteSymbols.note == "No language server is running — open a source file first.")
        model.symbolSource = { _, prefix, query in PaletteSymbols(entries: prefix == "#" && query == "Row" ? Self.symbols : []) }
        await model.loadPaletteSymbols(for: "#Row")
        #expect(model.paletteSymbols.entries.count == 3)
    }

    /// ⌘↵ opens in the split (making one, showing only that file); ⌥↵ in a new, stacked group; with two panes
    /// both use the other one. A symbol lands on its line.
    @Test func commandAndOptionReturnOpenBeside() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("forge-beside-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["a.swift", "b.swift", "c.swift"] {
            try "let x = 1\n".write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let model = ForgeModel(store: ForgeStore(documents: MemoryDocs()))
        await model.start(launch: folder.appendingPathComponent("a.swift").path)
        model.palette = ""
        model.openFromPalette("b.swift", in: .split)
        #expect(model.palette == nil && model.panes.count == 2 && !model.stacked)
        #expect(model.panes[1].paths == ["b.swift"] && model.activePane == 1)
        model.openFromPalette("c.swift", line: 3, in: .newGroup)
        #expect(model.activePane == 0 && model.panes[0].active == "c.swift" && model.pendingLine == 3)
        model.closePane()
        model.openFromPalette("b.swift", in: .newGroup)
        #expect(model.stacked && model.panes.count == 2 && model.panes[1].paths == ["b.swift"])
        model.openFromPalette("a.swift", in: .here)
        #expect(model.panes.count == 2 && model.panes[1].active == "a.swift")
    }
}
