import Testing

@testable import ForgeFeature

@Suite("Tabs")
struct TabsTests {
    @Test func singleClicksReuseOnePreviewTab() {
        var tabs = Tabs()
        tabs.open("a.swift", pinned: false)
        tabs.open("b.swift", pinned: false)
        #expect(tabs.paths == ["b.swift"])
        #expect(tabs.preview == "b.swift")
        #expect(tabs.active == "b.swift")
    }

    @Test func pinningKeepsTheTabAndTheNextPreviewOpensBesideIt() {
        var tabs = Tabs()
        tabs.open("a.swift", pinned: false)
        tabs.pin("a.swift")
        tabs.open("b.swift", pinned: false)
        #expect(tabs.paths == ["a.swift", "b.swift"])
        #expect(tabs.preview == "b.swift")
    }

    @Test func doubleClickOnThePreviewPinsIt() {
        var tabs = Tabs()
        tabs.open("a.swift", pinned: false)
        tabs.open("a.swift", pinned: true)
        #expect(tabs.preview == nil)
        #expect(tabs.paths == ["a.swift"])
    }

    @Test func newTabsOpenRightOfTheActiveOne() {
        var tabs = Tabs()
        tabs.open("a", pinned: true)
        tabs.open("b", pinned: true)
        tabs.activate("a")
        tabs.open("c", pinned: true)
        #expect(tabs.paths == ["a", "c", "b"])
    }

    @Test func closingTheActiveTabActivatesItsRightNeighbourThenLeft() {
        var tabs = Tabs()
        for path in ["a", "b", "c"] { tabs.open(path, pinned: true) }
        tabs.activate("b")
        tabs.close("b")
        #expect(tabs.active == "c")
        tabs.close("c")
        #expect(tabs.active == "a")
        tabs.close("a")
        #expect(tabs.active == nil)
    }

    @Test func renameFollowsTheFile() {
        var tabs = Tabs()
        tabs.open("old.swift", pinned: false)
        tabs.rename("old.swift", to: "new.swift")
        #expect(tabs.paths == ["new.swift"])
        #expect(tabs.active == "new.swift")
        #expect(tabs.preview == "new.swift")
    }
}
