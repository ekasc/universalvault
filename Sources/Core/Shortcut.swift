import Foundation

/// Modifier flags for a global shortcut.
///
/// Raw values match the Carbon modifier masks (`cmdKey`, `shiftKey`,
/// `optionKey`, `controlKey`) so the App layer can hand them straight to
/// `RegisterEventHotKey` without a translation table. Keeping the bit layout in
/// Core avoids linking Carbon into the testable, Apple-security-free module.
public struct ShortcutModifiers: OptionSet, Codable, Equatable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let command = ShortcutModifiers(rawValue: 0x0100)
    public static let shift = ShortcutModifiers(rawValue: 0x0200)
    public static let option = ShortcutModifiers(rawValue: 0x0800)
    public static let control = ShortcutModifiers(rawValue: 0x1000)

    /// Modifiers that make a shortcut safe to register globally. Shift alone
    /// would intercept ordinary typing.
    public static let required: ShortcutModifiers = [.command, .option, .control]

    /// Apple's conventional modifier order.
    public var displayString: String {
        var s = ""
        if contains(.control) { s += "⌃" }
        if contains(.option) { s += "⌥" }
        if contains(.shift) { s += "⇧" }
        if contains(.command) { s += "⌘" }
        return s
    }
}

/// Display names for Carbon virtual key codes.
///
/// The set is limited to keys that make sense as a global shortcut target:
/// letters, digits, common punctuation, whitespace keys, navigation keys and
/// function keys. Anything outside the table fails validation rather than
/// registering a shortcut the user cannot read.
public enum ShortcutKey {
    private static let names: [UInt32: String] = [
        0x00: "A", 0x0B: "B", 0x08: "C", 0x02: "D", 0x0E: "E", 0x03: "F", 0x05: "G",
        0x04: "H", 0x22: "I", 0x26: "J", 0x28: "K", 0x25: "L", 0x2E: "M", 0x2D: "N",
        0x1F: "O", 0x23: "P", 0x0C: "Q", 0x0F: "R", 0x01: "S", 0x11: "T", 0x20: "U",
        0x09: "V", 0x0D: "W", 0x07: "X", 0x10: "Y", 0x06: "Z",
        0x1D: "0", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x17: "5",
        0x16: "6", 0x1A: "7", 0x1C: "8", 0x19: "9",
        0x18: "=", 0x1B: "-", 0x1E: "]", 0x21: "[", 0x27: "'", 0x29: ";",
        0x2A: "\\", 0x2B: ",", 0x2C: "/", 0x2F: ".", 0x32: "`",
        // Escape is deliberately absent: the recorder uses it to cancel, and a
        // global Escape intercept would be hostile to every other app.
        0x24: "↩", 0x30: "⇥", 0x31: "Space", 0x33: "⌫", 0x75: "⌦",
        0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
        0x73: "↖", 0x77: "↘", 0x74: "⇞", 0x79: "⇟",
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6",
        0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
    ]

    /// Key codes that are themselves modifiers. A shortcut cannot be built from
    /// these, so the recorder ignores them instead of capturing a dead chord.
    public static let modifierKeyCodes: Set<UInt32> = [0x37, 0x36, 0x38, 0x3C, 0x3A, 0x3D, 0x3B, 0x3E, 0x39, 0x3F]

    public static func display(for keyCode: UInt32) -> String? { names[keyCode] }
    public static func isSupported(_ keyCode: UInt32) -> Bool { names[keyCode] != nil }
}

public enum HotKeyValidationError: Error, LocalizedError, Equatable {
    case missingModifier
    case unsupportedKey

    public var errorDescription: String? {
        switch self {
        case .missingModifier: return "Choose a shortcut that includes ⌘, ⌥ or ⌃."
        case .unsupportedKey: return "That key cannot be used for a global shortcut."
        }
    }
}

/// A global shortcut: one virtual key code plus its modifier mask.
public struct HotKeyShortcut: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: ShortcutModifiers

    public init(keyCode: UInt32, modifiers: ShortcutModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Control+Option+V, the shortcut documented in the README.
    public static let `default` = HotKeyShortcut(keyCode: 0x09, modifiers: [.control, .option])

    /// Human-readable form, e.g. `⌃⌥V`.
    public var displayString: String {
        modifiers.displayString + (ShortcutKey.display(for: keyCode) ?? "?")
    }

    public func validate() throws {
        guard !modifiers.intersection(ShortcutModifiers.required).isEmpty else {
            throw HotKeyValidationError.missingModifier
        }
        guard ShortcutKey.isSupported(keyCode) else {
            throw HotKeyValidationError.unsupportedKey
        }
    }

    public var isValid: Bool {
        (try? validate()) != nil
    }
}

/// Persistence for the chosen shortcut.
///
/// Stored outside the vault because the shortcut must exist while the vault is
/// locked; without it the user cannot even be told the vault is locked.
public struct ShortcutPreferences {
    private static let storageKey = "universalvault.globalShortcut"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Returns the stored shortcut, or the default when nothing valid is stored.
    public func load() -> HotKeyShortcut {
        guard let data = defaults.data(forKey: Self.storageKey),
              let shortcut = try? JSONDecoder().decode(HotKeyShortcut.self, from: data),
              shortcut.isValid
        else { return .default }
        return shortcut
    }

    public func save(_ shortcut: HotKeyShortcut) {
        guard let data = try? JSONEncoder().encode(shortcut) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
