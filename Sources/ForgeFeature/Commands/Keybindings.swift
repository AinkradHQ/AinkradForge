import AinkradAppKit
import SwiftUI

/// A shortcut as Forge saves it: the key, the modifiers' raw bits, and whether it follows ⌘K.
extension Shortcut: Codable {
    private enum CodingKeys: String, CodingKey { case key, modifiers, afterCommandK }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let text = try c.decode(String.self, forKey: .key)
        guard text.count == 1, let key = text.first else {
            throw DecodingError.dataCorruptedError(forKey: .key, in: c, debugDescription: "not one key: \(text)")
        }
        self.init(
            key: key, modifiers: EventModifiers(rawValue: try c.decode(Int.self, forKey: .modifiers)),
            afterCommandK: (try? c.decodeIfPresent(Bool.self, forKey: .afterCommandK)) ?? false)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(String(key), forKey: .key)
        try c.encode(modifiers.rawValue, forKey: .modifiers)
        if afterCommandK { try c.encode(true, forKey: .afterCommandK) }
    }
}

/// The palette's ⌘K: a command's shortcut, rebound by the user over its default and saved in Forge's store.
extension ForgeModel {
    /// The chord that runs `command` now: the user's, else the default.
    func shortcut(for command: ForgeCommand) -> Shortcut? {
        store.document.shortcuts?[command.rawValue] ?? command.shortcut
    }

    /// "New Terminal (⌃⇧`)": a tooltip naming the chord that runs `command` now — the user's, after a rebind.
    func titled(_ title: String, _ command: ForgeCommand) -> String {
        shortcut(for: command).map { "\(title) (\($0.display))" } ?? title
    }

    /// "✓ Keep ⌘↵": a label with the chord after it, the user's after a rebind.
    func labelled(_ title: String, _ command: ForgeCommand) -> String {
        shortcut(for: command).map { "\(title) \($0.display)" } ?? title
    }

    /// Why `shortcut` cannot run `command` — the host's, macOS's, another command's, or no modifier — or nil.
    func rejection(of shortcut: Shortcut, for command: ForgeCommand) -> String? {
        if shortcut == command.shortcut { return nil }
        if Self.reserved(shortcut) { return "\(shortcut.display) belongs to Ainkrad or macOS — pick another." }
        let bare = shortcut.modifiers.subtracting(.shift).isEmpty
        if bare, !Self.isFunctionKey(shortcut.key) { return "Hold ⌘, ⌃ or ⌥ with the key (or use a function key)." }
        if let other = ForgeCommand.allCases.first(where: { $0 != command && self.shortcut(for: $0) == shortcut }) {
            return "\(shortcut.display) already runs “\(other.paletteTitle)”."
        }
        return nil
    }

    /// Binds `command` to `shortcut`, or (nil) back to its default.
    func rebind(_ command: ForgeCommand, to shortcut: Shortcut?) {
        store.update { document in
            var all = document.shortcuts ?? [:]
            all[command.rawValue] = shortcut == command.shortcut ? nil : shortcut
            document.shortcuts = all.isEmpty ? nil : all
        }
    }

    /// The host's chords (Ainkrad takes them before an app unless the focused app claims them, FD36 — Forge
    /// does that only for its own defaults) and the system's that never reach an app.
    static func reserved(_ shortcut: Shortcut) -> Bool {
        guard !shortcut.afterCommandK else { return false }
        let key = shortcut.key
        let mods = shortcut.modifiers
        let command: EventModifiers = .command
        let arrows: Set<Character> = ["\u{F700}", "\u{F701}", "\u{F702}", "\u{F703}"]
        if mods == command, "k,wdmqh \t".contains(key) || ("1"..."9").contains(key) || arrows.contains(key) { return true }
        if mods == [.command, .shift], "anpd ".contains(key) || arrows.contains(key) { return true }
        if mods == [.command, .option], key == "\u{F702}" || key == "\u{F703}" || key == "h" { return true }
        if mods == .option, key == "\t" || ("1"..."9").contains(key) { return true }
        if mods == [.control, .option], key == " " { return true }
        return false
    }

    static func isFunctionKey(_ key: Character) -> Bool {
        key.unicodeScalars.first.map { (0xF704...0xF716).contains($0.value) } ?? false
    }

    /// The palette's `>` rows contributed by other Ainkrad apps are listed only while that app is installed and
    /// enabled; a host that cannot say keeps them (the app then answers for itself).
    func isAppAvailable(for command: ForgeCommand) -> Bool {
        guard let app = command.app, let apps else { return true }
        return apps.appAvailability(appID: app) != false
    }
}
