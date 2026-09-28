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

    func testImageImportModeUsesFolderThenAppAndPersists() {
        let defaults = isolatedDefaults()
        let store = EditorSettingsStore(defaults: defaults)
        let document = URL(fileURLWithPath: "/tmp/work/chapter/README.md")
        XCTAssertEqual(store.imageImportMode(for: document), .managedCopy)

        store.setImageImportMode(.relativeReference)
        XCTAssertEqual(store.imageImportMode(for: document), .relativeReference)
        store.setFolderSettings(FolderEditorSettings(defaultMode: nil, fontSize: nil,
                                                      imageImportMode: .managedCopy),
                                for: URL(fileURLWithPath: "/tmp/work"))
        XCTAssertEqual(store.imageImportMode(for: document), .managedCopy)
        XCTAssertEqual(EditorSettingsStore(defaults: defaults).imageImportMode(for: nil), .relativeReference)
    }

    func testOldAppSettingsDecodeWithoutImageImportMode() throws {
        let data = Data(#"{"defaultMode":"split","fontSize":13,"lineSpacing":3,"wrapsLines":true}"#.utf8)
        let decoded = try JSONDecoder().decode(AppEditorSettings.self, from: data)
        XCTAssertNil(decoded.imageImportMode)
        XCTAssertNil(decoded.fontChoice)
        XCTAssertNil(decoded.horizontalMargin)
        XCTAssertNil(decoded.verticalMargin)
        XCTAssertNil(decoded.tabWidth)
        XCTAssertNil(decoded.listIndentWidth)
        XCTAssertNil(decoded.codeIndentWidth)
        XCTAssertNil(decoded.editorZoom)
        XCTAssertNil(decoded.previewZoom)
    }

    func testTextStyleResolvesFolderSizeAndAppAppearance() {
        let defaults = isolatedDefaults()
        let store = EditorSettingsStore(defaults: defaults)
        var app = store.app
        app.fontChoice = .menlo
        app.fontSize = 15
        app.lineSpacing = 5
        app.horizontalMargin = 24
        app.verticalMargin = 20
        store.setAppSettings(app)
        let folder = URL(fileURLWithPath: "/tmp/work")
        let document = folder.appendingPathComponent("README.md")
        store.setFolderSettings(FolderEditorSettings(fontSize: 19), for: folder)

        XCTAssertEqual(store.textStyle(for: document), EditorTextStyle(
            fontChoice: .menlo, fontSize: 19, lineSpacing: 5,
            horizontalMargin: 24, verticalMargin: 20
        ))
        XCTAssertEqual(store.textStyle(for: nil).fontSize, 15)
        XCTAssertEqual(EditorSettingsStore(defaults: defaults).textStyle(for: document).fontChoice, .menlo)
    }

    func testFontSizeCommandsPreserveFontAndSpacing() {
        let store = EditorSettingsStore(defaults: isolatedDefaults())
        var app = store.app
        app.fontChoice = .system
        app.lineSpacing = 7
        app.fontSize = 31
        store.setAppSettings(app)

        store.adjustFontSize(by: 3)
        XCTAssertEqual(store.app.fontSize, 32)
        store.adjustFontSize(by: -50)
        XCTAssertEqual(store.app.fontSize, 10)
        store.resetFontSize()
        XCTAssertEqual(store.app.fontSize, 13)
        XCTAssertEqual(store.app.fontChoice, .system)
        XCTAssertEqual(store.app.lineSpacing, 7)
    }

    func testLayoutOptionsPersistAndTabWidthIsIndependentOfIndentWidth() {
        let defaults = isolatedDefaults()
        let store = EditorSettingsStore(defaults: defaults)
        var app = store.app
        app.wrapsLines = false
        app.tabWidth = 6
        app.listIndentWidth = 4
        app.codeIndentWidth = 8
        store.setAppSettings(app)

        let restored = EditorSettingsStore(defaults: defaults)
        XCTAssertEqual(restored.layoutOptions(), EditorLayoutOptions(
            wrapsLines: false, listIndentWidth: 4, codeIndentWidth: 8
        ))
        XCTAssertEqual(restored.textStyle(for: nil).tabWidth, 6)
    }

    func testEditorAndPreviewZoomPersistIndependentlyAndClamp() {
        let defaults = isolatedDefaults()
        let store = EditorSettingsStore(defaults: defaults)
        XCTAssertEqual(store.zoom(for: .editor), 1)
        XCTAssertEqual(store.zoom(for: .preview), 1)

        store.adjustZoom(for: .editor, by: 0.3)
        store.adjustZoom(for: .preview, by: -0.2)
        XCTAssertEqual(store.textStyle(for: nil).fontSize, 13 * 1.3, accuracy: 0.001)
        let restored = EditorSettingsStore(defaults: defaults)
        XCTAssertEqual(restored.zoom(for: .editor), 1.3, accuracy: 0.001)
        XCTAssertEqual(restored.zoom(for: .preview), 0.8, accuracy: 0.001)

        store.adjustZoom(for: .preview, by: 10)
        XCTAssertEqual(store.zoom(for: .preview), 2)
        store.resetZoom(for: .editor)
        XCTAssertEqual(store.zoom(for: .editor), 1)
        XCTAssertEqual(store.zoom(for: .preview), 2)
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "MKTownEditorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
