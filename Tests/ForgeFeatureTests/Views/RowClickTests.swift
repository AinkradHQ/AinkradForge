import AinkradAppKit
import AppKit
import SwiftUI
import XCTest

@testable import ForgeFeature

/// Tree rows are plain buttons now, for Full Keyboard Access (E1D1 FD34): a click must still preview at once
/// and a double click still pin. A borderless window far off screen, behind everything; mouse events sent to it
/// directly.
@MainActor
final class RowClickTests: XCTestCase {
    func testAClickOpensAndADoubleClickPins() throws {
        var clicks = 0
        var doubles = 0
        let row = FileRow(
            node: FileNode(path: "a.swift", name: "a.swift", isDirectory: false, children: []), depth: 0, mark: nil,
            isExpanded: false, isSelected: false, onClick: { clicks += 1 }, onDoubleClick: { doubles += 1 })
        let host = NSHostingView(rootView: row.frame(width: 240, height: 24).ainkradSkin(.standard))
        host.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -3000, y: -3000))
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        SweepSupport.spin(until: 0.3) { false }

        func click(_ count: Int) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(
                    with: type, location: NSPoint(x: 60, y: 12), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1)
                if let event { window.sendEvent(event) }
            }
        }
        click(1)
        SweepSupport.spin(until: 1) { clicks == 1 }
        XCTAssertEqual(clicks, 1)
        XCTAssertEqual(doubles, 0)
        click(2)
        SweepSupport.spin(until: 1) { doubles == 1 }
        XCTAssertEqual(doubles, 1)
    }
}
