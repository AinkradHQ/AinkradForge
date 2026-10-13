import AppKit
import SwiftUI

/// Takes the app's next key press, once, before anything else sees it (a local monitor), and swallows it: the
/// second step of a ⌘K chord, or a shortcut being recorded.
@MainActor
final class NextKey {
    private var monitor: Any?

    var isListening: Bool { monitor != nil }

    /// `handle` returns whether it is done; until then every key press goes to it.
    func listen(_ handle: @escaping @MainActor (NSEvent) -> Bool) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { if handle(event) { self?.stop() } }
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

extension Shortcut {
    /// The chord a key press makes: its key as typed without modifiers (⇧⌘5 is "5" with ⇧⌘, not "%").
    init?(event: NSEvent, afterCommandK: Bool = false) {
        guard let key = event.characters(byApplyingModifiers: [])?.lowercased().first else { return nil }
        let flags = event.modifierFlags
        var modifiers: EventModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        self.init(key: key, modifiers: modifiers, afterCommandK: afterCommandK)
    }
}
