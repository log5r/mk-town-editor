import AppKit
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

    func testEveryFixedMenuShortcutIsReserved() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("Sources/MKTownEditor"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        let pattern = try NSRegularExpression(
            pattern: #"\.keyboardShortcut\("(.)", modifiers: (\.\w+|\[[^\]]*\])\)"#)
        var found: [ShortcutChord] = []
        for url in sources {
            let text = try String(contentsOf: url, encoding: .utf8)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let key = String(text[Range(match.range(at: 1), in: text)!])
                let modifiers = String(text[Range(match.range(at: 2), in: text)!])
                found.append(ShortcutChord(key: key, command: modifiers.contains("command"),
                                           option: modifiers.contains("option"),
                                           shift: modifiers.contains("shift"),
                                           control: modifiers.contains("control")))
            }
        }
        XCTAssertGreaterThanOrEqual(found.count, 20)
        for chord in found {
            XCTAssertTrue(EditorShortcutRegistry.reserved.contains(chord), "\(chord.label) is not reserved")
        }
    }

    func testSystemWindowShortcutsAreRejectedAndDefaultsAvoidThem() {
        for chord in [ShortcutChord(key: "`"), ShortcutChord(key: "`", shift: true),
                      ShortcutChord(key: "t", option: true), ShortcutChord(key: "[", option: true)] {
            XCTAssertThrowsError(try EditorShortcutRegistry.validate(chord, for: .bold, overrides: [:])) { error in
                XCTAssertEqual(error as? ShortcutError, .reserved, chord.label)
            }
        }
        // Find keeps ⌘F, which the preview search shares, but no other command may take it.
        XCTAssertNoThrow(try EditorShortcutRegistry.validate(ShortcutChord(key: "f"), for: .find, overrides: [:]))
        XCTAssertThrowsError(try EditorShortcutRegistry.validate(ShortcutChord(key: "f"), for: .bold,
                                                                 overrides: [:]))
        var seen: [ShortcutChord: EditorCommand] = [:]
        for command in EditorShortcutRegistry.commands {
            guard let chord = EditorShortcutRegistry.shortcut(for: command, overrides: [:]) else { continue }
            XCTAssertNil(seen[chord], "\(command.title) and \(seen[chord]?.title ?? "") share \(chord.label)")
            seen[chord] = command
            XCTAssertNoThrow(try EditorShortcutRegistry.validate(chord, for: command, overrides: [:]),
                             "\(command.title) \(chord.label)")
            XCTAssertEqual(chord.key, chord.key.lowercased())
            XCTAssertFalse(chord.shift && "~!@#$%^&*()_+{}|:\"<>?".contains(chord.key),
                           "\(command.title) adds Shift to a shifted character")
        }
        XCTAssertEqual(EditorShortcutRegistry.shortcut(for: .inlineCode, overrides: [:])?.label, "⇧⌘C")
        XCTAssertEqual(EditorShortcutRegistry.shortcut(for: .quote, overrides: [:])?.label, "⌘>")
    }

    func testShiftedCharacterShortcutMatchesTheKeyThatTypesIt() {
        func matches(key: String, shift: Bool, characters: String, flags: NSEvent.ModifierFlags) -> Bool {
            let menu = NSMenu()
            let item = NSMenuItem(title: "Quote", action: #selector(ShortcutTarget.shortcutFired(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = shift ? [.command, .shift] : .command
            // NSMenuItem holds its target weakly.
            let target = ShortcutTarget()
            item.target = target
            menu.addItem(item)
            defer { withExtendedLifetime(target) {} }
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                         timestamp: 0, windowNumber: 0, context: nil, characters: characters,
                                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 47)!
            return menu.performKeyEquivalent(with: event)
        }
        let quote = ShortcutChord(key: EditorCommand.quote.shortcut!.key,
                                  modifiers: EditorCommand.quote.shortcut!.modifiers)
        // ⇧⌘. on a US or ABC layout types ">"; ⌘. alone must stay free.
        XCTAssertTrue(matches(key: quote.key, shift: quote.shift, characters: ">", flags: [.command, .shift]))
        XCTAssertFalse(matches(key: quote.key, shift: quote.shift, characters: ".", flags: .command))
        // Shift on the unshifted key never matches, because AppKit compares the typed character.
        XCTAssertFalse(matches(key: ".", shift: true, characters: ">", flags: [.command, .shift]))
    }

    func testUserAssignmentWinsOverANewDefaultForTheSameKey() {
        let overrides = [EditorCommand.highlight.toolbarIdentifier: ShortcutChord(key: "c", shift: true)]
        XCTAssertEqual(EditorShortcutRegistry.shortcut(for: .highlight, overrides: overrides)?.label, "⇧⌘C")
        XCTAssertNil(EditorShortcutRegistry.shortcut(for: .inlineCode, overrides: overrides))
        XCTAssertEqual(EditorShortcutRegistry.shortcut(for: .inlineCode, overrides: [:])?.label, "⇧⌘C")
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

private final class ShortcutTarget: NSObject {
    var hits = 0
    @objc func shortcutFired(_ sender: Any?) { hits += 1 }
}
