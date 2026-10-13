import AinkradAppKit
import AppKit
import SwiftUI
import XCTest

@testable import ForgeFeature

/// Mockup 08 has no "▸ Replace" while Replace is open, so Esc in the replace field is the way to close it. Off
/// screen, behind everything; the key event is sent to the window directly.
@MainActor
final class ReplaceEscTests: XCTestCase {
    func testEscInTheReplaceFieldClosesReplace() throws {
        let repo = try SampleRepo.make()
        defer { try? FileManager.default.removeItem(at: repo.deletingLastPathComponent()) }
        let model = try SweepSupport.model(opening: repo)
        let workspace = try XCTUnwrap(model.workspace)
        let host = NSHostingView(rootView: SearchPanel(model: model, workspace: workspace).frame(width: 280, height: 400).ainkradSkin(.standard))
        host.frame = NSRect(x: 0, y: 0, width: 280, height: 400)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -3000, y: -3000))
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        SweepSupport.spin(until: 0.3) { false }

        model.search.isReplaceOpen = true
        // Opening hands the replace field the keyboard a turn later.
        model.search.replacement = "isActive"
        SweepSupport.spin(until: 2) { (window.firstResponder as? NSTextView)?.string == "isActive" }
        XCTAssertEqual((window.firstResponder as? NSTextView)?.string, "isActive", "the replace field has the keyboard")

        let esc = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false, keyCode: 53)
        window.sendEvent(try XCTUnwrap(esc))
        SweepSupport.spin(until: 2) { !model.search.isReplaceOpen }
        XCTAssertFalse(model.search.isReplaceOpen)
    }
}
