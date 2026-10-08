import AppKit
import XCTest
@testable import MKTownEditor

/// Settings use tabs, apply changes immediately, record shortcuts from key presses, and can hide
/// line numbers (#52).
@MainActor
final class SettingsWindowTests: XCTestCase {
    private func makeStore() -> EditorSettingsStore {
        let suite = "SettingsWindowTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return EditorSettingsStore(defaults: defaults)
    }

    private func keyEvent(_ characters: String, unmodified: String, keyCode: UInt16,
                          modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                         windowNumber: 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: unmodified, isARepeat: false, keyCode: keyCode)!
    }

    func testRecordedKeysFollowTheDefaultShortcutConventions() {
        XCTAssertEqual(ShortcutChord(recordedKey: "b", shifted: "B", modifiers: .command),
                       ShortcutChord(key: "b"))
        XCTAssertEqual(ShortcutChord(recordedKey: "x", shifted: "X", modifiers: [.command, .shift]),
                       ShortcutChord(key: "x", shift: true))
        XCTAssertEqual(ShortcutChord(recordedKey: "8", shifted: "*", modifiers: [.command, .shift]),
                       ShortcutChord(key: "8", shift: true))
        // Shifted punctuation is stored as the character AppKit matches, like the ⌘> default.
        XCTAssertEqual(ShortcutChord(recordedKey: ".", shifted: ">", modifiers: [.command, .shift]),
                       ShortcutChord(key: ">"))
        XCTAssertEqual(ShortcutChord(recordedKey: "k", shifted: "K", modifiers: [.command, .option, .control]),
                       ShortcutChord(key: "k", option: true, control: true))
        XCTAssertNil(ShortcutChord(recordedKey: "", shifted: "", modifiers: .command))
    }

    func testRecorderCapturesCommandKeysOnlyWhileFocused() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let recorder = ShortcutRecorderView(frame: NSRect(x: 0, y: 0, width: 120, height: 22))
        window.contentView?.addSubview(recorder)
        var recorded: [ShortcutChord] = []
        var cleared = 0
        recorder.onRecord = { recorded.append($0) }
        recorder.onClear = { cleared += 1 }

        let commandK = keyEvent("k", unmodified: "k", keyCode: 40, modifiers: .command)
        XCTAssertFalse(recorder.performKeyEquivalent(with: commandK))
        XCTAssertTrue(window.makeFirstResponder(recorder))
        XCTAssertTrue(recorder.isRecording)
        XCTAssertTrue(recorder.performKeyEquivalent(with: commandK))
        XCTAssertEqual(recorded, [ShortcutChord(key: "k")])
        XCTAssertFalse(recorder.isRecording, "Recording ends once a key is applied")

        window.makeFirstResponder(recorder)
        recorder.keyDown(with: keyEvent("\u{1B}", unmodified: "\u{1B}", keyCode: 53, modifiers: []))
        XCTAssertEqual(recorded.count, 1, "Escape cancels")
        window.makeFirstResponder(recorder)
        recorder.keyDown(with: keyEvent("\u{7F}", unmodified: "\u{7F}", keyCode: 51, modifiers: []))
        XCTAssertEqual(cleared, 1, "Delete removes the shortcut")
    }

    func testClearedShortcutStaysRemovedUntilReset() throws {
        let store = makeStore()
        XCTAssertEqual(store.shortcut(for: .bold)?.label, "⌘B")
        store.clearShortcut(for: .bold)
        XCTAssertNil(store.shortcut(for: .bold))
        // The freed key can go to another command.
        XCTAssertNoThrow(try store.setShortcut(ShortcutChord(key: "b"), for: .italic))
        try store.setShortcut(ShortcutChord(key: "i"), for: .italic)
        try store.resetShortcut(for: .bold)
        XCTAssertEqual(store.shortcut(for: .bold)?.label, "⌘B")
    }

    func testLineNumbersCanBeHidden() {
        let store = makeStore()
        XCTAssertTrue(store.layoutOptions().showsLineNumbers)
        var settings = store.app
        settings.showsLineNumbers = false
        store.setAppSettings(settings)
        let options = store.layoutOptions()
        XCTAssertFalse(options.showsLineNumbers)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let text = NSTextView(frame: scroll.bounds)
        scroll.documentView = text
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        options.apply(to: text, in: scroll)
        XCTAssertFalse(scroll.rulersVisible)
        EditorLayoutOptions().apply(to: text, in: scroll)
        XCTAssertTrue(scroll.rulersVisible)
    }

    func testSettingsAreSplitIntoTabsWithoutASaveButton() throws {
        let panes = EditorPreferencesView.Pane.allCases
        XCTAssertEqual(panes.count, 7)
        XCTAssertEqual(Set(panes.map(\.title)).count, panes.count)
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/MKTownEditor")
        for name in ["EditorPreferencesView.swift", "EditorShortcuts.swift"] {
            let text = try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
            XCTAssertFalse(text.contains("Button(\"設定を保存\")"), name)
            XCTAssertFalse(text.contains("TextField(\"キー（1文字）\""), name)
        }
    }
}
