import Foundation
import XCTest
@testable import MKTownEditor

@MainActor
final class SettingsArchiveTests: XCTestCase {
    func testAllCategoriesRoundTripAndPersistInAnotherStore() throws {
        let sourceDefaults = try isolatedDefaults()
        let destinationDefaults = try isolatedDefaults()
        let source = makeStore(sourceDefaults)
        let destination = makeStore(destinationDefaults)
        let package = try JSONDecoder().decode(DeclarativeExtension.self, from: Data(packageJSON.utf8))
        var settings = source.app
        settings.defaultMode = .editor
        settings.documentOpeningMode = .lastUsed
        settings.loadsExternalLinkPreviews = true
        settings.editorFont = .family("Hiragino Sans")
        settings.fontSize = 16
        settings.disabledLintRules = [.headingHierarchy, .listMarker]
        settings.previewBodyWidth = 1040
        settings.preservesSoftLineBreaksInPreview = true
        settings.editorThemeFollowsAppearance = true
        settings.editorDarkTheme = .navy
        settings.previewTheme = .extensionTheme(try XCTUnwrap(package.theme))
        settings.extensionPackages = [package]
        settings.snippets = [EditorSnippet(trigger: "foot", template: "[^$0]")]
        settings.terminologyEntries = [TerminologyEntry(prohibited: "Github", preferred: "GitHub")]
        settings.terminologyOptions = TerminologyOptions(excludesCode: false)
        source.setAppSettings(settings)
        source.clearShortcut(for: .find)
        source.setDetectionEnabled(false, for: .shiftJIS)
        var preset = MarkdownExportPreset.standard
        preset.name = "冊子"
        preset.font = .serif
        let savedPreset = try MarkdownExportPresetStore(defaults: sourceDefaults).save(preset)

        let categories = Set(SettingsArchive.Category.allCases)
        let archive = try SettingsArchive(data: source.exportSettings(categories: categories))
        XCTAssertEqual(archive.categories, categories)
        let differences = archive.differences(from: destination.settingsArchiveSnapshot)
        for category in categories {
            XCTAssertFalse(try XCTUnwrap(differences[category]).isEmpty, category.rawValue)
        }
        XCTAssertTrue(try XCTUnwrap(differences[.general]).contains { $0.contains("→") })
        try destination.importSettings(archive, categories: archive.categories)

        let reopened = makeStore(destinationDefaults)
        XCTAssertEqual(reopened.settingsArchiveSnapshot, source.settingsArchiveSnapshot)
        XCTAssertNil(reopened.shortcut(for: .find))
        XCTAssertEqual(MarkdownExportPresetStore(defaults: destinationDefaults).load(), [.standard, savedPreset])
        XCTAssertTrue(archive.differences(from: reopened.settingsArchiveSnapshot).values.allSatisfy(\.isEmpty))
    }

    func testSelectiveExportAndImportKeepLocalStateAndResetAnExplicitDefault() throws {
        let sourceDefaults = try isolatedDefaults()
        let destinationDefaults = try isolatedDefaults()
        let source = makeStore(sourceDefaults)
        let destination = makeStore(destinationDefaults)
        let sourceURL = URL(fileURLWithPath: "/private/tmp/source-settings/document.md")
        let localURL = URL(fileURLWithPath: "/private/tmp/local-settings/document.md")
        let pathSettings = ["graphvizRendererPath", "plantUMLJarPath", "MKTownEditor.pandocPath"]
        for key in pathSettings {
            sourceDefaults.set("/private/tmp/source-tools/tool", forKey: key)
            destinationDefaults.set("/private/tmp/local-tools/tool", forKey: key)
        }
        source.setMode(.preview, for: sourceURL)
        source.setFolderSettings(FolderEditorSettings(fontSize: 17), for: sourceURL.deletingLastPathComponent())
        source.addBookmark(.capture(in: "Secret source bookmark", at: 0, documentURL: sourceURL))
        destination.setMode(.editor, for: localURL)
        destination.setFolderSettings(FolderEditorSettings(fontSize: 21), for: localURL.deletingLastPathComponent())
        let bookmark = DocumentBookmark.capture(in: "Local bookmark", at: 0, documentURL: localURL)
        destination.addBookmark(bookmark)

        var incoming = source.app
        incoming.loadsRemoteImages = true
        incoming.fontSize = 27
        incoming.previewBodyWidth = 1200
        source.setAppSettings(incoming)
        var local = destination.app
        local.fontSize = 22
        local.tabWidth = 8
        local.previewBodyWidth = 720
        destination.setAppSettings(local)

        let data = try source.exportSettings(categories: [.general, .editor])
        let raw = String(decoding: data, as: UTF8.self)
        for excluded in ["source-settings", "source-tools", "Secret source bookmark",
                         "previewBodyWidth", "bookmarks", "documentDisplayStates"] {
            XCTAssertFalse(raw.contains(excluded), excluded)
        }
        let archive = try SettingsArchive(data: data)
        XCTAssertEqual(archive.categories, [.general, .editor])
        try destination.importSettings(archive, categories: [.editor, .preview])

        XCTAssertEqual(destination.app.fontSize, 27)
        XCTAssertNil(destination.app.tabWidth)
        XCTAssertEqual(destination.app.previewBodyWidth, 720)
        XCTAssertNil(destination.app.loadsRemoteImages)
        XCTAssertEqual(destination.displayState(for: localURL)?.mode, .editor)
        XCTAssertEqual(destination.folderSettings(for: localURL.deletingLastPathComponent()).fontSize, 21)
        XCTAssertEqual(destination.bookmarks, [bookmark])
        for key in pathSettings {
            XCTAssertEqual(destinationDefaults.string(forKey: key), "/private/tmp/local-tools/tool")
        }
    }

    func testUnknownKeysAndEnumValuesKeepLocalSettings() throws {
        let defaults = try isolatedDefaults()
        let store = makeStore(defaults)
        var settings = store.app
        settings.fontChoice = .menlo
        settings.previewTheme = .paper
        settings.fontFamily = "Some Family"
        store.setAppSettings(settings)
        let data = Data("""
        {
          "format": "MKTownEditor-settings", "futureRoot": [true, {}],
          "categories": {
            "general": {"attachmentDirectory": "future", "loadsRemoteImages": false, "exampleFuture": 42},
            "editor": {"fontChoice": "future", "fontSize": 18, "unknownField": {"value": null}},
            "themes": {"previewTheme": "future"},
            "futureCategory": ["ignored"],
            "shortcuts": {"overrides": {"future-command": "ignored"}},
            "extensions": {"executablePath": "/tmp/untrusted"}
          }
        }
        """.utf8)
        let archive = try SettingsArchive(data: data)
        XCTAssertEqual(archive.categories, [.general, .editor])

        try store.importSettings(archive, categories: Set(SettingsArchive.Category.allCases))
        XCTAssertEqual(store.app.fontSize, 18)
        XCTAssertEqual(store.app.loadsRemoteImages, false)
        XCTAssertEqual(store.app.fontChoice, .menlo)
        XCTAssertEqual(store.app.fontFamily, "Some Family")
        XCTAssertEqual(store.app.previewTheme, .paper)
        XCTAssertNil(store.app.attachmentDirectory)
        XCTAssertNil(store.app.extensionPackages)
    }

    func testMalformedArchiveCannotApplyEvenAValidCategory() throws {
        let defaults = try isolatedDefaults()
        let store = makeStore(defaults)
        let invalidSections = [
            #""editor":{"fontSize":"large"}"#,
            #""editor":{"fontSize":1e300}"#,
            #""editor":{"readingEstimate":{"language":"japanese","japaneseReadingRate":9223372036854775807,"japaneseSpeakingRate":300,"englishReadingRate":200,"englishSpeakingRate":130}}"#,
            #""themes":{"editorTheme":42}"#,
            #""themes":{"previewTheme":"navy"}"#,
            #""extensions":[] "#,
            #""exportPresets":{"presets":[{"id":"not-a-uuid","name":"Broken"}]}"#,
            """
            "shortcuts":{"overrides":{"\(EditorCommand.bold.toolbarIdentifier)":
            {"key":"x","command":false,"option":false,"shift":false,"control":false}}}
            """,
        ]
        for section in invalidSections {
            let data = Data("""
            {"format":"MKTownEditor-settings","categories":{"general":{"loadsRemoteImages":true},\(section)}}
            """.utf8)
            XCTAssertThrowsError(try SettingsArchive(data: data), section)
        }
        XCTAssertThrowsError(try SettingsArchive(data: Data("{".utf8)))
        XCTAssertThrowsError(try SettingsArchive(data: Data(#"{"format":"other-file","categories":{}}"#.utf8)))
        XCTAssertNil(store.app.loadsRemoteImages)
        XCTAssertEqual(store.settingsWriteCount, 0)
    }

    func testReviewDetectsContentChangesButIgnoresUnselectedLocalEdits() throws {
        let source = makeStore(try isolatedDefaults())
        let destination = makeStore(try isolatedDefaults())
        let snippet = EditorSnippet(trigger: "note", template: "source template")
        var settings = source.app
        settings.snippets = [snippet]
        source.setAppSettings(settings)
        var local = destination.app
        var localSnippet = snippet
        localSnippet.template = "local template"
        local.snippets = [localSnippet]
        destination.setAppSettings(local)

        let archive = try SettingsArchive(data: source.exportSettings(categories: [.snippets, .editor]))
        let difference = try XCTUnwrap(archive.differences(from: destination.settingsArchiveSnapshot)[.snippets])
        XCTAssertEqual(difference.count, 1)
        XCTAssertTrue(try XCTUnwrap(difference.first).contains("note"))
        let reviewed = destination.settingsArchiveSnapshot
        local.fontSize = 16
        destination.setAppSettings(local)
        XCTAssertTrue(archive.affectedSettingsMatch(reviewed, destination.settingsArchiveSnapshot, categories: [.snippets]))
        local.snippets?[0].template = "another template"
        destination.setAppSettings(local)
        XCTAssertFalse(archive.affectedSettingsMatch(reviewed, destination.settingsArchiveSnapshot, categories: [.snippets]))
    }

    private func isolatedDefaults() throws -> UserDefaults {
        let name = "mktown-settings-archive-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func makeStore(_ defaults: UserDefaults) -> EditorSettingsStore {
        EditorSettingsStore(defaults: defaults, prunesMissingDocuments: false, appearance: .light)
    }

    private let packageJSON = """
    {"schemaVersion":1,"id":"example.notes","name":"Notes",
     "theme":{"name":"Night","background":"#000000","body":"#FFFFFF",
       "heading":"#FFFFFF","code":"#FFFFFF","link":"#FFFFFF","codeBackground":"#000000"},
     "snippets":[{"trigger":"sig","template":"${1:名前}$0"}]}
    """
}
