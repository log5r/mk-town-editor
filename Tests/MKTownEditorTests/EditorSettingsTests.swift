import Foundation
import XCTest
@testable import MKTownEditor

@MainActor
final class EditorSettingsTests: XCTestCase {
    func testSplitSizingReservesMinimumForBothPanes() {
        XCTAssertEqual(EditorSplitSizing.editorExtent(total: 1000, ratio: 0.3,
            minimum: 280), 297.6, accuracy: 0.001)
        XCTAssertEqual(EditorSplitSizing.editorExtent(total: 1000, ratio: 0,
            minimum: 280), 280)
        XCTAssertEqual(EditorSplitSizing.editorExtent(total: 1000, ratio: 1,
            minimum: 280), 712)
        XCTAssertEqual(EditorSplitSizing.editorExtent(total: 600, ratio: 0.5,
            minimum: 180), 296)
        XCTAssertEqual(EditorSplitSizing.editorExtent(total: 400, ratio: 0,
            minimum: 280), 196)
    }

    func testFocusModeRestoresPreviousSidebarVisibilityAcrossRepeatedToggles() {
        var state = FocusModeState()
        XCTAssertEqual(state.toggle(sidebarVisibility: .all), .detailOnly)
        XCTAssertTrue(state.isActive)
        XCTAssertEqual(state.savedSidebarVisibility, .all)
        XCTAssertEqual(state.toggle(sidebarVisibility: .detailOnly), .all)
        XCTAssertFalse(state.isActive)
        XCTAssertEqual(state.toggle(sidebarVisibility: .detailOnly), .detailOnly)
        XCTAssertEqual(state.toggle(sidebarVisibility: .detailOnly), .detailOnly)
        XCTAssertFalse(state.isActive)
    }

    func testBookmarksPersistAndFollowDocumentRename() {
        let defaults = isolatedDefaults()
        let original = URL(fileURLWithPath: "/tmp/work/old.md")
        let renamed = URL(fileURLWithPath: "/tmp/work/new.md")
        let store = EditorSettingsStore(defaults: defaults)
        let bookmark = DocumentBookmark.capture(in: "# 見出し\n本文", at: 7,
            documentURL: original)
        store.addBookmark(bookmark)
        store.moveDocumentState(from: original, to: renamed)
        let restored = EditorSettingsStore(defaults: defaults)
        XCTAssertEqual(restored.bookmarks.first?.documentURL, renamed)
        XCTAssertEqual(restored.bookmarks.first?.id, bookmark.id)
        restored.removeBookmark(bookmark.id)
        XCTAssertTrue(EditorSettingsStore(defaults: defaults).bookmarks.isEmpty)
    }

    func testBookmarksFollowWorkspaceFolderMove() {
        let defaults = isolatedDefaults()
        let store = EditorSettingsStore(defaults: defaults)
        let original = URL(fileURLWithPath: "/tmp/work/old/chapter.md")
        store.addBookmark(DocumentBookmark.capture(in: "本文", at: 1,
            documentURL: original))
        store.moveBookmarks(under: URL(fileURLWithPath: "/tmp/work/old"),
            to: URL(fileURLWithPath: "/tmp/work/new"))
        XCTAssertEqual(store.bookmarks.first?.documentURL,
            URL(fileURLWithPath: "/tmp/work/new/chapter.md"))
    }

    func testUserSnippetsPersistWithoutChangingDocument() {
        let defaults = isolatedDefaults()
        let store = EditorSettingsStore(defaults: defaults)
        var settings = store.app
        settings.snippets = [EditorSnippet(trigger: "sig", template: "${1:名前}$0")]
        store.setAppSettings(settings)
        let reloaded = EditorSettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.app.snippets, settings.snippets)
    }

    func testRemoteImagePreferenceDefaultsOffAndPersists() {
        let defaults = isolatedDefaults()
        let store = EditorSettingsStore(defaults: defaults)
        XCTAssertNil(store.app.loadsRemoteImages)
        var settings = store.app
        settings.loadsRemoteImages = true
        store.setAppSettings(settings)
        XCTAssertEqual(EditorSettingsStore(defaults: defaults).app.loadsRemoteImages, true)
    }

    func testInlineLivePresentationPreferenceDefaultsOffAndPersists() {
        let defaults = isolatedDefaults()
        let store = EditorSettingsStore(defaults: defaults)
        XCTAssertNil(store.app.usesInlineLivePresentation)
        var settings = store.app
        settings.usesInlineLivePresentation = true
        store.setAppSettings(settings)
        XCTAssertEqual(EditorSettingsStore(defaults: defaults).app.usesInlineLivePresentation, true)
    }
    func testTypewriterModePreferenceDefaultsOffAndPersists() {
        let defaults = isolatedDefaults()
        let store = EditorSettingsStore(defaults: defaults)
        XCTAssertNil(store.app.usesTypewriterMode)
        var settings = store.app
        settings.usesTypewriterMode = true
        store.setAppSettings(settings)
        XCTAssertEqual(EditorSettingsStore(defaults: defaults).app.usesTypewriterMode, true)
    }
    func testTerminologyDictionaryAndExclusionsPersist() {
        let defaults = isolatedDefaults()
        let store = EditorSettingsStore(defaults: defaults)
        XCTAssertNil(store.app.terminologyEntries)
        var settings = store.app
        settings.terminologyEntries = [TerminologyEntry(prohibited: "colour", preferred: "color")]
        settings.terminologyOptions = TerminologyOptions(excludesCode: true, excludesQuotes: false)
        store.setAppSettings(settings)
        let restored = EditorSettingsStore(defaults: defaults).app
        XCTAssertEqual(restored.terminologyEntries, settings.terminologyEntries)
        XCTAssertEqual(restored.terminologyOptions, settings.terminologyOptions)
    }
    func testPreviewThemeAndWidthPersist() {
        let defaults = isolatedDefaults()
        let store = EditorSettingsStore(defaults: defaults)
        XCTAssertNil(store.app.previewTheme)
        var settings = store.app
        settings.previewTheme = .paper
        settings.previewBodyWidth = 720
        store.setAppSettings(settings)
        let restored = EditorSettingsStore(defaults: defaults)
        XCTAssertEqual(restored.app.previewTheme, .paper)
        XCTAssertEqual(restored.app.previewBodyWidth, 720)
    }
    func testInvisibleDisplayPreferencesPersist() {
        let defaults = isolatedDefaults()
        let store = EditorSettingsStore(defaults: defaults)
        var settings = store.app
        settings.showsInvisibleCharacters = true
        settings.showsIndentGuides = true
        store.setAppSettings(settings)
        let restored = EditorSettingsStore(defaults: defaults)
        XCTAssertEqual(restored.app.showsInvisibleCharacters, true)
        XCTAssertEqual(restored.app.showsIndentGuides, true)
    }
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

    func testFolderLookupTerminatesAtFilesystemRootAfterSavingInTemporaryDirectory() {
        let store = EditorSettingsStore(defaults: isolatedDefaults())
        let document = URL(fileURLWithPath: "/private/tmp/mktown-settings-save-regression.md")
        store.setFolderSettings(FolderEditorSettings(defaultMode: .preview),
                                for: URL(fileURLWithPath: "/"))

        XCTAssertEqual(store.mode(for: document), .preview)
        XCTAssertEqual(store.fontSize(for: document), store.app.fontSize)
        XCTAssertEqual(store.markdownDialect(for: document), .extended)
    }

    func testFolderEditingOverridesInheritNearestConfiguredValueAndPersist() {
        let defaults = isolatedDefaults()
        let store = EditorSettingsStore(defaults: defaults)
        let root = URL(fileURLWithPath: "/tmp/book")
        let chapter = root.appendingPathComponent("chapter")
        let document = chapter.appendingPathComponent("README.md")
        var app = store.app
        app.tabWidth = 3
        app.listIndentWidth = 3
        app.attachmentDirectory = .assets
        app.markdownDialect = .extended
        store.setAppSettings(app)
        store.setFolderSettings(FolderEditorSettings(tabWidth: 6,
            attachmentDirectory: .images, markdownDialect: .basic), for: root)
        store.setFolderSettings(FolderEditorSettings(codeIndentWidth: 7), for: chapter)

        XCTAssertEqual(store.textStyle(for: document).tabWidth, 6)
        XCTAssertEqual(store.layoutOptions(for: document).listIndentWidth, 3)
        XCTAssertEqual(store.layoutOptions(for: document).codeIndentWidth, 7)
        XCTAssertEqual(store.attachmentDirectory(for: document), .images)
        XCTAssertEqual(store.markdownDialect(for: document), .basic)
        XCTAssertEqual(store.attachmentDirectory(for: nil), .assets)
        let restored = EditorSettingsStore(defaults: defaults)
        XCTAssertEqual(restored.folderSettings(for: root).tabWidth, 6)
        XCTAssertEqual(restored.markdownDialect(for: document), .basic)
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

    func testDocumentPositionPersistsAndModeChangeKeepsIt() throws {
        let defaults = isolatedDefaults()
        let url = URL(fileURLWithPath: "/tmp/work/position.md")
        let store = EditorSettingsStore(defaults: defaults)
        store.savePosition(for: url, selection: NSRange(location: 42, length: 5), scrollX: 12,
                           scrollY: 123, splitRatio: 0.65,
                           sidebarTab: "ファイル", sidebarVisible: true,
                           splitOrientation: .stacked, previewFirst: true)
        store.setMode(.preview, for: url)
        let restored = try XCTUnwrap(EditorSettingsStore(defaults: defaults).displayState(for: url))
        XCTAssertEqual(restored.mode, .preview)
        XCTAssertEqual(restored.selectionLocation, 42)
        XCTAssertEqual(restored.selectionLength, 5)
        XCTAssertEqual(restored.scrollY, 123)
        XCTAssertEqual(restored.scrollX, 12)
        XCTAssertEqual(restored.splitRatio, 0.65)
        XCTAssertEqual(restored.splitOrientation, .stacked)
        XCTAssertEqual(restored.previewFirst, true)
        XCTAssertEqual(restored.sidebarTab, "ファイル")
        XCTAssertEqual(restored.sidebarVisible, true)
        store.moveDocumentState(from: url, to: url.deletingLastPathComponent()
            .appendingPathComponent("renamed.md"))
        XCTAssertNil(store.displayState(for: url))
    }

    func testOldDocumentStateDecodesWithPositionDefaults() throws {
        let state = try JSONDecoder().decode(DocumentDisplayState.self,
                                             from: Data(#"{"mode":"split"}"#.utf8))
        XCTAssertNil(state.selectionLocation)
        XCTAssertNil(state.splitRatio)
        XCTAssertNil(state.splitOrientation)
        XCTAssertNil(state.previewFirst)
        XCTAssertNil(state.sidebarTab)
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

    func testWordCountModePersistsAndOldAppSettingsDecode() throws {
        let defaults = isolatedDefaults()
        let store = EditorSettingsStore(defaults: defaults)
        XCTAssertNil(store.app.wordCountMode)
        var settings = store.app
        settings.wordCountMode = .japanese
        store.setAppSettings(settings)
        XCTAssertEqual(EditorSettingsStore(defaults: defaults).app.wordCountMode, .japanese)
        let old = try JSONDecoder().decode(AppEditorSettings.self,
            from: Data(#"{"defaultMode":"split","fontSize":13,"lineSpacing":3,"wrapsLines":true}"#.utf8))
        XCTAssertNil(old.wordCountMode)
        XCTAssertNil(old.readingEstimate)
    }

    func testReadingEstimateSettingsPersist() {
        let defaults = isolatedDefaults()
        let store = EditorSettingsStore(defaults: defaults)
        var settings = store.app
        var estimate = ReadingEstimateSettings()
        estimate.language = .english
        estimate.englishReadingRate = 240
        settings.readingEstimate = estimate
        store.setAppSettings(settings)
        XCTAssertEqual(EditorSettingsStore(defaults: defaults).app.readingEstimate, estimate)
    }

    func testDisabledLintRulesPersist() {
        let defaults = isolatedDefaults()
        let store = EditorSettingsStore(defaults: defaults)
        var settings = store.app
        settings.disabledLintRules = [.headingHierarchy, .listMarker]
        store.setAppSettings(settings)
        XCTAssertEqual(EditorSettingsStore(defaults: defaults).app.disabledLintRules,
                       [.headingHierarchy, .listMarker])
    }

    func testProofingPreferencesPersistAndOldSettingsUseDefaults() throws {
        let defaults = isolatedDefaults()
        let store = EditorSettingsStore(defaults: defaults)
        var settings = store.app
        settings.proofing = EditorProofingSettings(language: .english,
            checksSpelling: true, correctsSpelling: false)
        store.setAppSettings(settings)
        XCTAssertEqual(EditorSettingsStore(defaults: defaults).app.proofing, settings.proofing)
        let old = try JSONDecoder().decode(AppEditorSettings.self,
            from: Data(#"{"defaultMode":"split","fontSize":13,"lineSpacing":3,"wrapsLines":true}"#.utf8))
        XCTAssertNil(old.proofing)
        XCTAssertTrue(EditorProofingSettings().correctsSpelling)
    }

    func testFrontMatterPreviewVisibilityPersists() {
        let defaults = isolatedDefaults()
        let store = EditorSettingsStore(defaults: defaults)
        var settings = store.app
        settings.showsFrontMatterInPreview = true
        store.setAppSettings(settings)
        XCTAssertEqual(EditorSettingsStore(defaults: defaults).app.showsFrontMatterInPreview, true)
    }

    func testProofingContextExcludesCodeAndURLsButNotAdjacentProse() {
        let source = "text `coode` https://exaample.com next\n```\ncoode\n```\nnormal"
        let text = source as NSString
        let ranges = MarkdownProofingContext.protectedRanges(in: source)
        XCTAssertTrue(MarkdownProofingContext.isProtected(text.range(of: "coode").location + 1,
            in: ranges))
        let url = text.range(of: "https://exaample.com")
        XCTAssertTrue(MarkdownProofingContext.isProtected(NSMaxRange(url), in: ranges))
        XCTAssertFalse(MarkdownProofingContext.isProtected(text.range(of: "next").location,
            in: ranges))
        XCTAssertTrue(MarkdownProofingContext.isProtected(text.range(of: "coode", options: [],
            range: NSRange(location: NSMaxRange(url), length: text.length - NSMaxRange(url))).location,
            in: ranges))
        XCTAssertFalse(MarkdownProofingContext.isProtected(text.range(of: "normal").location,
            in: ranges))
    }

    func testOpeningSessionCapturesTextBeforeAnalysisCompletes() async throws {
        let defaults = isolatedDefaults()
        let store = EditorSettingsStore(defaults: defaults)
        let analysis = DocumentAnalysisStore()
        let url = URL(fileURLWithPath: "/tmp/work/initial.md")
        let text = "既存の本文👨‍👩‍👧‍👦é"
        analysis.update(source: text)
        XCTAssertNil(analysis.snapshot)
        store.ensureWritingSession(for: url, initialText: text)
        XCTAssertEqual(store.displayState(for: url)?.sessionBaselineCharacters, text.count)
        for _ in 0..<500 where analysis.snapshot == nil { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertNotNil(analysis.snapshot)
        XCTAssertEqual(try XCTUnwrap(analysis.snapshot).statistics.characters -
            store.displayState(for: url)!.sessionBaselineCharacters!, 0)
        store.ensureWritingSession(for: url, initialText: text + "追記")
        let reopened = EditorSettingsStore(defaults: defaults)
        reopened.ensureWritingSession(for: url, initialText: text + "追記")
        XCTAssertEqual(reopened.displayState(for: url)?.sessionBaselineCharacters, text.count)
    }

    func testSessionBaselineCountsCharactersLikeDocumentStatistics() {
        // The panel subtracts the baseline from DocumentStatistics.characters; both must count
        // the same units, including emoji sequences, combining marks and CRLF.
        for text in ["", "既存の本文👨‍👩‍👧‍👦é", "line\r\nline\n", "e\u{301}🙂 \t"] {
            XCTAssertEqual(WritingSessionBaseline(text: text).characters, DocumentStatistics(text: text).characters, text)
        }
    }

    func testWritingGoalAndSessionBaselinePersistAndFollowRename() {
        let defaults = isolatedDefaults()
        let oldURL = URL(fileURLWithPath: "/tmp/work/draft.md")
        let newURL = URL(fileURLWithPath: "/tmp/work/final.md")
        let store = EditorSettingsStore(defaults: defaults)
        store.ensureWritingSession(for: oldURL, baseline: WritingSessionBaseline(text: String(repeating: "a", count: 120)))
        store.ensureWritingSession(for: oldURL, baseline: WritingSessionBaseline(text: String(repeating: "a", count: 140)))
        store.setWritingGoal(500, for: oldURL)
        store.moveDocumentState(from: oldURL, to: newURL)

        let restored = EditorSettingsStore(defaults: defaults)
        XCTAssertNil(restored.displayState(for: oldURL))
        XCTAssertEqual(restored.displayState(for: newURL)?.writingGoal, 500)
        XCTAssertEqual(restored.displayState(for: newURL)?.sessionBaselineCharacters, 120)
        restored.resetWritingSession(for: newURL, baseline: WritingSessionBaseline(text: String(repeating: "a", count: 150)))
        XCTAssertEqual(EditorSettingsStore(defaults: defaults)
            .displayState(for: newURL)?.sessionBaselineCharacters, 150)
        restored.setWritingGoal(nil, for: newURL)
        XCTAssertNil(restored.displayState(for: newURL)?.writingGoal)
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
        XCTAssertNil(decoded.tableAddsRowOnTab)
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

    func testTableTabPreferencePersists() {
        let defaults = isolatedDefaults()
        let store = EditorSettingsStore(defaults: defaults)
        var app = store.app
        app.tableAddsRowOnTab = false
        store.setAppSettings(app)
        XCTAssertEqual(EditorSettingsStore(defaults: defaults).app.tableAddsRowOnTab, false)
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

    func testSavingPositionDoesNotNotifyObserversButModeChangesDo() {
        let store = EditorSettingsStore(defaults: isolatedDefaults(), prunesMissingDocuments: false)
        let url = URL(fileURLWithPath: "/tmp/work/observed.md")
        var changes = 0
        let observation = store.objectWillChange.sink { changes += 1 }
        for location in 0..<5 {
            store.savePosition(for: url, selection: NSRange(location: location, length: 0), scrollX: 0,
                               scrollY: Double(location), splitRatio: 0.5, sidebarTab: "outline",
                               sidebarVisible: true)
        }
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(store.displayState(for: url)?.scrollY, 4)
        store.setMode(.preview, for: url)
        XCTAssertEqual(changes, 1)
        var app = store.app
        app.fontSize = 15
        store.setAppSettings(app)
        XCTAssertEqual(changes, 2)
        withExtendedLifetime(observation) {}
    }

    func testDocumentStatesAreStoredSeparatelyAndBoundedByRecency() throws {
        let defaults = isolatedDefaults()
        let store = EditorSettingsStore(defaults: defaults, prunesMissingDocuments: false)
        let limit = EditorSettingsStore.documentStateLimit
        let urls = (0..<(limit + 25)).map { URL(fileURLWithPath: "/tmp/work/doc\($0).md") }
        for url in urls { store.setMode(.split, for: url) }
        store.setMode(.preview, for: urls[0])
        XCTAssertEqual(store.documentStateCount, limit)
        XCTAssertTrue(store.hasDocumentState(for: urls[0]), "Recently used state is kept")
        XCTAssertFalse(store.hasDocumentState(for: urls[1]), "Oldest state is removed")
        XCTAssertTrue(store.hasDocumentState(for: urls.last!))

        store.setImageImportMode(.relativeReference)
        let settingsData = try XCTUnwrap(defaults.data(forKey: "MKTownEditor.editorSettings.v1"))
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: settingsData) as? [String: Any])
        XCTAssertEqual((settings["documents"] as? [String: Any])?.count, 0,
                       "Document states are not encoded with shared settings")
        let restored = EditorSettingsStore(defaults: defaults, prunesMissingDocuments: false)
        XCTAssertEqual(restored.documentStateCount, limit)
        XCTAssertEqual(restored.mode(for: urls[0]), .preview)
    }

    func testLegacyCombinedStorageIsMigratedAndUnchangedSettingsAreNotRewritten() throws {
        let defaults = isolatedDefaults()
        let legacy = """
        {"app":{"defaultMode":"split","fontSize":14,"lineSpacing":2,"wrapsLines":true},
         "folders":{},"documents":{"/tmp/work/legacy.md":{"mode":"preview","scrollY":50}}}
        """
        defaults.set(Data(legacy.utf8), forKey: "MKTownEditor.editorSettings.v1")
        let store = EditorSettingsStore(defaults: defaults, prunesMissingDocuments: false)
        let url = URL(fileURLWithPath: "/tmp/work/legacy.md")
        XCTAssertEqual(store.mode(for: url), .preview)
        XCTAssertEqual(store.app.fontSize, 14)
        XCTAssertNotNil(defaults.data(forKey: "MKTownEditor.documentDisplayStates.v1"))
        let restored = EditorSettingsStore(defaults: defaults, prunesMissingDocuments: false)
        XCTAssertEqual(restored.displayState(for: url)?.scrollY, 50)

        let writes = restored.settingsWriteCount
        restored.setAppSettings(restored.app)
        restored.setAppSettings(restored.app)
        XCTAssertEqual(restored.settingsWriteCount, writes)
        let documentWrites = restored.documentWriteCount
        restored.savePosition(for: url, selection: NSRange(location: 0, length: 0), scrollX: 0, scrollY: 50,
                              splitRatio: 0.5, sidebarTab: "outline", sidebarVisible: true)
        restored.savePosition(for: url, selection: NSRange(location: 0, length: 0), scrollX: 0, scrollY: 50,
                              splitRatio: 0.5, sidebarTab: "outline", sidebarVisible: true)
        XCTAssertEqual(restored.documentWriteCount, documentWrites + 1)
        XCTAssertEqual(restored.settingsWriteCount, writes, "Position saves do not rewrite shared settings")
    }

    func testMigratedStatesWithoutRecencyAreNotTrimmedArbitrarily() throws {
        let defaults = isolatedDefaults()
        let legacyDocuments = (0..<250).map { "\"/tmp/work/legacy\($0).md\":{\"mode\":\"preview\"}" }
            .joined(separator: ",")
        let legacy = "{\"app\":{\"defaultMode\":\"split\",\"fontSize\":13,\"lineSpacing\":3," +
            "\"wrapsLines\":true},\"folders\":{},\"documents\":{\(legacyDocuments)}}"
        defaults.set(Data(legacy.utf8), forKey: "MKTownEditor.editorSettings.v1")
        let store = EditorSettingsStore(defaults: defaults, prunesMissingDocuments: false)
        XCTAssertEqual(store.documentStateCount, 250, "Legacy states have no recency to choose by")
        let limit = EditorSettingsStore.documentStateLimit
        for index in 0..<(limit + 10) {
            store.setMode(.split, for: URL(fileURLWithPath: "/tmp/work/new\(index).md"))
        }
        XCTAssertEqual(store.documentStateCount, 250 + limit)
        XCTAssertFalse(store.hasDocumentState(for: URL(fileURLWithPath: "/tmp/work/new0.md")))
        XCTAssertTrue(store.hasDocumentState(for: URL(fileURLWithPath: "/tmp/work/legacy0.md")))
        store.setMode(.editor, for: URL(fileURLWithPath: "/tmp/work/legacy0.md"))
        XCTAssertEqual(store.mode(for: URL(fileURLWithPath: "/tmp/work/legacy0.md")), .editor)
        XCTAssertEqual(store.documentStateCount, 249 + limit, "A rewritten legacy state joins the bounded set")
    }

    func testMissingDocumentsArePrunedButUnreachableFoldersAreKept() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("kept.md")
        try Data("x".utf8).write(to: existing)
        let removed = root.appendingPathComponent("removed.md")
        let unmounted = URL(fileURLWithPath: "/Volumes/MKTownMissingVolume-\(UUID().uuidString)/note.md")
        let store = EditorSettingsStore(defaults: isolatedDefaults(), prunesMissingDocuments: false)
        for url in [existing, removed, unmounted] { store.setMode(.preview, for: url) }
        await store.pruneMissingDocuments()
        XCTAssertTrue(store.hasDocumentState(for: existing))
        XCTAssertFalse(store.hasDocumentState(for: removed))
        XCTAssertTrue(store.hasDocumentState(for: unmounted))
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "MKTownEditorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
