import XCTest
import Core

final class ShortcutTests: XCTestCase {
    func testDefaultShortcutIsValidAndReadable() {
        XCTAssertTrue(HotKeyShortcut.default.isValid)
        XCTAssertEqual(HotKeyShortcut.default.displayString, "⌃⌥V")
    }

    func testModifierlessShortcutIsRejected() {
        let s = HotKeyShortcut(keyCode: 0x09, modifiers: [])
        XCTAssertThrowsError(try s.validate()) { error in
            XCTAssertEqual(error as? HotKeyValidationError, .missingModifier)
        }
        XCTAssertFalse(s.isValid)
    }

    func testShiftOnlyShortcutIsRejected() {
        let s = HotKeyShortcut(keyCode: 0x09, modifiers: [.shift])
        XCTAssertThrowsError(try s.validate()) { error in
            XCTAssertEqual(error as? HotKeyValidationError, .missingModifier)
        }
    }

    func testUnsupportedKeyIsRejected() {
        let s = HotKeyShortcut(keyCode: 0xFF, modifiers: [.command])
        XCTAssertThrowsError(try s.validate()) { error in
            XCTAssertEqual(error as? HotKeyValidationError, .unsupportedKey)
        }
    }

    func testEscapeIsNotRecordableAsAShortcut() {
        // The recorder uses Escape to abandon recording, and a global Escape
        // intercept would swallow every other app's Escape.
        XCTAssertFalse(ShortcutKey.isSupported(0x35))
        XCTAssertFalse(HotKeyShortcut(keyCode: 0x35, modifiers: [.command]).isValid)
    }

    func testModifierKeysAreNotShortcutTargets() {
        for code in ShortcutKey.modifierKeyCodes {
            XCTAssertFalse(ShortcutKey.isSupported(code), "modifier key \(code) must not be recordable")
        }
    }

    func testDisplayStringUsesAppleModifierOrder() {
        let s = HotKeyShortcut(keyCode: 0x09, modifiers: [.command, .shift, .option, .control])
        XCTAssertEqual(s.displayString, "⌃⌥⇧⌘V")
    }

    func testPreferencesRoundTrip() {
        let suite = "universalvault.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = ShortcutPreferences(defaults: defaults)

        let custom = HotKeyShortcut(keyCode: 0x08, modifiers: [.control, .command])
        prefs.save(custom)
        XCTAssertEqual(prefs.load(), custom)
    }

    func testPreferencesFallBackToDefaultWhenEmpty() {
        let suite = "universalvault.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(ShortcutPreferences(defaults: defaults).load(), .default)
    }

    func testPreferencesIgnoreCorruptAndInvalidStoredValues() {
        let suite = "universalvault.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = ShortcutPreferences(defaults: defaults)

        defaults.set(Data("not json".utf8), forKey: "universalvault.globalShortcut")
        XCTAssertEqual(prefs.load(), .default)

        // Structurally valid JSON, but a shortcut this app would refuse to register.
        let invalid = HotKeyShortcut(keyCode: 0x09, modifiers: [])
        defaults.set(try! JSONEncoder().encode(invalid), forKey: "universalvault.globalShortcut")
        XCTAssertEqual(prefs.load(), .default)
    }
}
