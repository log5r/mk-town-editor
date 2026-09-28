import Foundation
import XCTest
@testable import MKTownEditor

@MainActor
final class EditorShortcutsTests: XCTestCase {
    func testRegistryHasUniqueIdentifiersAndDefaultShortcuts() {
        let commands = EditorShortcutRegistry.commands
        XCTAssertEqual(Set(commands.map(\.toolbarIdentifier)).count, commands.count)
        XCTAssertEqual(EditorShortcutRegistry.shortcut(for: .bold, overrides: [:])?.label, "⌘B")
        XCTAssertEqual(EditorShortcutRegistry.shortcut(for: .heading(level: 0), overrides: [:])?.label,
                       "⌥⌘0")
    }

    func testRejectsDuplicateReservedAndUnmodifiedKeys() {
        XCTAssertThrowsError(try EditorShortcutRegistry.validate(ShortcutChord(key: "b"),
            for: .italic, overrides: [:])) { error in
            XCTAssertEqual(error as? ShortcutError, .duplicate("太字"))
        }
        XCTAssertThrowsError(try EditorShortcutRegistry.validate(ShortcutChord(key: "q"),
            for: .bold, overrides: [:])) { error in
            XCTAssertEqual(error as? ShortcutError, .reserved)
        }
        XCTAssertThrowsError(try EditorShortcutRegistry.validate(ShortcutChord(key: "v"),
            for: .bold, overrides: [:])) { error in
            XCTAssertEqual(error as? ShortcutError, .reserved)
        }
        XCTAssertThrowsError(try EditorShortcutRegistry.validate(
            ShortcutChord(key: "z", command: false), for: .bold, overrides: [:])) { error in
            XCTAssertEqual(error as? ShortcutError, .modifierRequired)
        }
        XCTAssertThrowsError(try EditorShortcutRegistry.validate(ShortcutChord(key: "ab"),
            for: .bold, overrides: [:])) { error in
            XCTAssertEqual(error as? ShortcutError, .invalidKey)
        }
    }

    func testOverridePersistsAndResetRestoresDefault() throws {
        let suite = "shortcut-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = EditorSettingsStore(defaults: defaults)
        try store.setShortcut(ShortcutChord(key: "J", option: true), for: .bold)
        let restored = EditorSettingsStore(defaults: defaults)
        XCTAssertEqual(restored.shortcut(for: .bold)?.label, "⌥⌘J")
        try restored.resetShortcut(for: .bold)
        XCTAssertEqual(EditorSettingsStore(defaults: defaults).shortcut(for: .bold)?.label, "⌘B")
    }

    func testResetCannotReintroduceCollisionWithAnotherOverride() throws {
        let suite = "shortcut-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = EditorSettingsStore(defaults: defaults)
        try store.setShortcut(ShortcutChord(key: "j", option: true), for: .bold)
        try store.setShortcut(ShortcutChord(key: "b"), for: .italic)
        XCTAssertThrowsError(try store.resetShortcut(for: .bold)) { error in
            XCTAssertEqual(error as? ShortcutError, .duplicate("斜体"))
        }
        XCTAssertEqual(store.shortcut(for: .bold)?.label, "⌥⌘J")
    }
}
