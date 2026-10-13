import AppKit
import SwiftUI

/// Takes the app's next key press, once, before anything else sees it (a local monitor), and swallows it: the
/// second step of a ⌘K chord, or a shortcut being recorded. Only while Forge has the keyboard (FD47): a key
/// press in another window, or once Forge's pane loses focus (a click on a Rune terminal beside it), ends the
/// listening — the key goes where it was typed, and `onRelease` lets the caller put its state back.
@MainActor
final class NextKey {
    private var monitor: Any?
    /// The window Forge was in when listening began.
    private weak var window: NSWindow?
    private var onRelease: (@MainActor () -> Void)?
    /// Whether Forge's pane has the keyboard; the view that listens keeps it current.
    var paneFocused = true {
        didSet { if !paneFocused { release() } }
    }

    var isListening: Bool { monitor != nil }

    /// `handle` returns whether it is done; until then every key press Forge gets goes to it.
    func listen(onRelease: @escaping @MainActor () -> Void = {}, _ handle: @escaping @MainActor (NSEvent) -> Bool) {
        stop()
        window = NSApp.keyWindow
        self.onRelease = onRelease
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let taken = MainActor.assumeIsolated {
                guard let self else { return false }
                guard Self.claims(eventWindow: event.window, window: self.window, paneFocused: self.paneFocused) else {
                    self.release()
                    return false
                }
                if handle(event) { self.stop() }
                return true
            }
            return taken ? nil : event
        }
    }

    /// Whether a key press is Forge's to take: typed in the window it listens in, while its pane has focus.
    nonisolated static func claims(eventWindow: NSWindow?, window: NSWindow?, paneFocused: Bool) -> Bool {
        paneFocused && eventWindow != nil && eventWindow === window
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        onRelease = nil
    }

    /// Stops listening because Forge lost the keyboard, and tells the caller.
    private func release() {
        guard isListening else { return }
        let done = onRelease
        stop()
        done?()
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
