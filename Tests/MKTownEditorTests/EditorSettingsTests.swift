import Foundation
import XCTest
@testable import MKTownEditor

@MainActor
final class EditorSettingsTests: XCTestCase {
    func testDefaultsAndDocumentFolderAppPrecedence() {
        let defaults = isolatedDefaults()
        let store = EditorSettingsStore(defaults: defaults)
        let document = URL(fileURLWithPath: "/tmp/work/chapter/README.md")
        var app = AppEditorSettings()
        app.defaultMode = .editor
        app.fontSize = 14
        store.setAppSettings(app)
        store.setFolderSettings(FolderEditorSettings(defaultMode: .preview, fontSize: 18),
                                for: URL(fileURLWithPath: "/tmp/work"))
        store.setFolderSettings(FolderEditorSettings(defaultMode: nil, fontSize: 20),
                                for: URL(fileURLWithPath: "/tmp/work/chapter"))

        XCTAssertEqual(store.mode(for: document), .preview)
        XCTAssertEqual(store.fontSize(for: document), 20)
        store.setMode(.split, for: document)
        XCTAssertEqual(store.mode(for: document), .split)
        XCTAssertEqual(store.mode(for: nil), .editor)
        XCTAssertEqual(store.fontSize(for: nil), 14)
    }

    func testSettingsPersistAndFollowRenamedDocument() {
        let defaults = isolatedDefaults()
        let oldURL = URL(fileURLWithPath: "/tmp/work/old.md")
        let newURL = URL(fileURLWithPath: "/tmp/work/new.md")
        let first = EditorSettingsStore(defaults: defaults)
        first.setMode(.preview, for: oldURL)
        first.moveDocumentState(from: oldURL, to: newURL)

        let restored = EditorSettingsStore(defaults: defaults)
        XCTAssertEqual(restored.mode(for: newURL), .preview)
        XCTAssertFalse(restored.hasDocumentState(for: oldURL))
    }

    func testLegacySceneModeMigratesOnlyWhenDocumentHasNoState() {
        let store = EditorSettingsStore(defaults: isolatedDefaults())
        let document = URL(fileURLWithPath: "/tmp/work/README.md")
        store.migrateLegacyMode("preview", for: document)
        store.migrateLegacyMode("editor", for: document)

        XCTAssertEqual(store.mode(for: document), .preview)
        store.migrateLegacyMode("invalid", for: URL(fileURLWithPath: "/tmp/work/other.md"))
        XCTAssertEqual(store.mode(for: URL(fileURLWithPath: "/tmp/work/other.md")), .split)
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "MKTownEditorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
