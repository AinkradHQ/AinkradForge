import AppKit
import Testing

@testable import ForgeFeature

/// FD47: a recording or a ⌘K chord takes keys only while Forge has the keyboard.
@MainActor
@Suite("Next key")
struct NextKeyTests {
    @Test func onlyForgesWindowWithItsPaneFocusedIsClaimed() {
        let forge = NSWindow()
        let other = NSWindow()
        #expect(NextKey.claims(eventWindow: forge, window: forge, paneFocused: true))
        #expect(!NextKey.claims(eventWindow: forge, window: forge, paneFocused: false))
        #expect(!NextKey.claims(eventWindow: other, window: forge, paneFocused: true))
        #expect(!NextKey.claims(eventWindow: nil, window: forge, paneFocused: true))
        #expect(!NextKey.claims(eventWindow: nil, window: nil, paneFocused: true))
    }

    @Test func losingPaneFocusReleasesTheListener() {
        let key = NextKey()
        var released = 0
        key.listen(onRelease: { released += 1 }) { _ in false }
        #expect(key.isListening)
        key.paneFocused = false
        #expect(!key.isListening && released == 1)
        // Released once; a stop the caller asks for is not a release.
        key.paneFocused = true
        key.listen(onRelease: { released += 1 }) { _ in false }
        key.stop()
        #expect(!key.isListening && released == 1)
    }
}
