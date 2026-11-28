import XCTest
@testable import MKTownEditor

/// 新しい版が書いた設定を以前の版が読めること（Issue #107）。docs/settings-backward-compatibility.md
@MainActor
final class SettingsBackwardCompatibilityTests: XCTestCase {
    private static let storageKey = "MKTownEditor.editorSettings.v1"

    private func isolatedDefaults() throws -> UserDefaults {
        let suite = "SettingsBackwardCompatibilityTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func storedJSON(in defaults: UserDefaults) throws -> String {
        try XCTUnwrap(String(data: XCTUnwrap(defaults.data(forKey: Self.storageKey)), encoding: .utf8))
    }

    /// テーマ以外の設定も入れた設定を保存する。
    private func saveSettings(in defaults: UserDefaults, editing: (inout AppEditorSettings) -> Void) {
        let store = EditorSettingsStore(defaults: defaults, prunesMissingDocuments: false, appearance: .dark)
        var settings = store.app
        settings.fontSize = 17
        settings.shortcutOverrides = ["togglePreview": ShortcutChord(key: "p", option: true)]
        settings.snippets = [EditorSnippet(trigger: "sig", template: "-- 署名")]
        editing(&settings)
        store.setAppSettings(settings)
        store.setFolderSettings(FolderEditorSettings(fontSize: 19, tabWidth: 2),
                                for: URL(fileURLWithPath: "/tmp/MKTownCompatibilityFolder"))
    }

    // MARK: - 以前の版での読み込み

    /// 「紺色」を選んで保存した設定を、`"navy"` を知らない以前の版（PR #98 より前）の形で読む。
    /// テーマの1項目で失敗せず、ショートカット、スニペット、フォルダごとの設定が残る。
    func testSettingsWithNavyAreReadableByVersionsBeforeNavy() throws {
        let defaults = try isolatedDefaults()
        saveSettings(in: defaults) { settings in
            settings.editorTheme = .navy
            settings.editorThemeFollowsAppearance = true
            settings.editorLightTheme = .paper
            settings.editorDarkTheme = .navy
            settings.previewTheme = .preset(.nord)
        }
        let json = try storedJSON(in: defaults)
        XCTAssertFalse(json.contains("\"navy\""), json)

        let earlier = try JSONDecoder().decode(EarlierStoredSettings.self, from: Data(json.utf8))
        XCTAssertEqual(earlier.app.fontSize, 17)
        XCTAssertEqual(earlier.app.shortcutOverrides, ["togglePreview": ShortcutChord(key: "p", option: true)])
        XCTAssertEqual(earlier.app.snippets?.map(\.template), ["-- 署名"])
        XCTAssertEqual(earlier.folders.values.first?.fontSize, 19)
        XCTAssertEqual(earlier.folders.values.first?.tabWidth, 2)
        // 以前の版の編集画面の「システム」は紺の背景の配色。
        XCTAssertEqual(earlier.app.editorTheme, .system)
        XCTAssertEqual(earlier.app.previewTheme, .preset(.nord))
    }

    /// 既定の設定（テーマ未設定）も以前の版で読める。
    func testDefaultSettingsAreReadableByVersionsBeforeNavy() throws {
        let defaults = try isolatedDefaults()
        saveSettings(in: defaults) { _ in }
        let earlier = try JSONDecoder().decode(EarlierStoredSettings.self,
                                               from: Data(try storedJSON(in: defaults).utf8))
        XCTAssertEqual(earlier.app.fontSize, 17)
        XCTAssertNil(earlier.app.editorTheme)
    }

    // MARK: - この版での往復

    func testSettingsWithoutWhitespaceOptionsKeepExistingSettingsAndUseDefaults() throws {
        let defaults = try isolatedDefaults()
        let json = #"{"app":{"defaultMode":"split","fontSize":17,"lineSpacing":3,"wrapsLines":true},"folders":{"/tmp/work":{"tabWidth":6}},"documents":{}}"#
        defaults.set(Data(json.utf8), forKey: Self.storageKey)
        let store = EditorSettingsStore(defaults: defaults, prunesMissingDocuments: false, appearance: .dark)
        let file = URL(fileURLWithPath: "/tmp/work/note.md")
        XCTAssertEqual(store.whitespaceEditingOptions(for: file), EditorWhitespaceEditingOptions())
        XCTAssertEqual(store.app.fontSize, 17)
        XCTAssertEqual(store.textStyle(for: file).tabWidth, 6)
    }

    func testUnknownIndentationStyleDoesNotDiscardOtherSettings() throws {
        let defaults = try isolatedDefaults()
        let json = #"{"app":{"defaultMode":"split","fontSize":17,"lineSpacing":3,"wrapsLines":true,"indentationStyle":"future-style","detectsIndentation":true},"folders":{"/tmp/work":{"tabWidth":6}},"documents":{}}"#
        defaults.set(Data(json.utf8), forKey: Self.storageKey)
        let store = EditorSettingsStore(defaults: defaults, prunesMissingDocuments: false, appearance: .dark)
        let file = URL(fileURLWithPath: "/tmp/work/note.md")
        XCTAssertEqual(store.whitespaceEditingOptions(for: file), EditorWhitespaceEditingOptions(detectsIndentation: true))
        XCTAssertEqual(store.app.fontSize, 17)
        XCTAssertEqual(store.textStyle(for: file).tabWidth, 6)
    }

    /// 「紺色」は保存して読み直しても「紺色」のまま。外観ごとの項目も同じ。
    func testNavyRoundTripsThroughTheStore() throws {
        let defaults = try isolatedDefaults()
        var saved = AppEditorSettings()
        saveSettings(in: defaults) { settings in
            settings.editorTheme = .navy
            settings.editorThemeFollowsAppearance = false
            settings.editorLightTheme = .navy
            settings.editorDarkTheme = .navy
            saved = settings
        }
        let reopened = EditorSettingsStore(defaults: defaults, prunesMissingDocuments: false, appearance: .dark)
        XCTAssertEqual(reopened.app, saved)
        XCTAssertEqual(reopened.app.editorTheme, .navy)
        XCTAssertEqual(reopened.app.editorLightTheme, .navy)
        XCTAssertEqual(reopened.app.editorDarkTheme, .navy)
        XCTAssertEqual(reopened.editorTheme, .navy)
        XCTAssertEqual(reopened.app.theme(for: .editor, slot: .fixed), .navy)
        // プレビューの「システム」は「紺色」にならない。
        XCTAssertEqual(reopened.previewTheme, .system)
    }

    /// 読み直した設定を同じ内容で保存しても、保存データは変わらない。
    func testReloadedNavyIsWrittenBackAsTheSameBytes() throws {
        let defaults = try isolatedDefaults()
        saveSettings(in: defaults) { $0.editorTheme = .navy }
        let before = try storedJSON(in: defaults)
        let reopened = EditorSettingsStore(defaults: defaults, prunesMissingDocuments: false, appearance: .dark)
        reopened.setAppSettings(reopened.app)
        XCTAssertEqual(try storedJSON(in: defaults), before)
        XCTAssertEqual(reopened.settingsWriteCount, 0, "内容が同じなら書き込まない")
    }

    /// `"navy"` を直接書いた版（PR #98〜Issue #107 の修正前）の保存データも「紺色」として読む。
    func testSettingsSavedWithTheNavyNameAreStillRead() throws {
        let defaults = try isolatedDefaults()
        let json = #"{"app":{"defaultMode":"split","fontSize":15,"lineSpacing":3,"wrapsLines":true,"#
            + #""editorTheme":"navy","editorThemeFollowsAppearance":true,"editorDarkTheme":"navy","#
            + #""shortcutOverrides":{"togglePreview":{"key":"p","command":true,"option":true,"shift":false,"control":false}}},"#
            + #""folders":{},"documents":{}}"#
        defaults.set(Data(json.utf8), forKey: Self.storageKey)
        let store = EditorSettingsStore(defaults: defaults, prunesMissingDocuments: false, appearance: .dark)
        XCTAssertEqual(store.app.fontSize, 15)
        XCTAssertEqual(store.app.editorTheme, .navy)
        XCTAssertEqual(store.app.editorDarkTheme, .navy)
        XCTAssertEqual(store.editorTheme, .navy)
        XCTAssertEqual(store.app.shortcutOverrides?["togglePreview"], ShortcutChord(key: "p", option: true))
    }

    // MARK: - 知らないテーマ

    /// 今後の版が足したテーマ名や読めない色の定義は、投げずに既定のテーマとして読む。
    /// ほかの設定は残る。
    func testUnknownThemesReadAsTheDefaultWithoutDroppingOtherSettings() throws {
        let defaults = try isolatedDefaults()
        let json = #"{"app":{"defaultMode":"split","fontSize":16,"lineSpacing":3,"wrapsLines":true,"#
            + #""editorTheme":"future-theme","previewTheme":"future-theme","previewDarkTheme":{"unexpected":1},"#
            + #""snippets":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","trigger":"sig","template":"-- 署名"}]},"#
            + #""folders":{},"documents":{}}"#
        defaults.set(Data(json.utf8), forKey: Self.storageKey)
        let store = EditorSettingsStore(defaults: defaults, prunesMissingDocuments: false, appearance: .dark)
        XCTAssertEqual(store.app.fontSize, 16, "the settings were dropped instead of read")
        XCTAssertEqual(store.app.snippets?.map(\.trigger), ["sig"])
        XCTAssertEqual(store.editorTheme, .navy, "編集画面の既定")
        XCTAssertEqual(store.previewTheme, .system, "プレビューの既定")
        XCTAssertEqual(store.app.previewDarkTheme, .system)
    }

    func testThemeNamesDecodeIndividually() throws {
        func decode(_ json: String) throws -> PreviewTheme {
            try JSONDecoder().decode(PreviewTheme.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try decode(#""system""#), .system)
        XCTAssertEqual(try decode(#""navy""#), .navy)
        XCTAssertEqual(try decode(#""paper""#), .paper)
        XCTAssertEqual(try decode(#""github-dark""#), .preset(.githubDark))
        XCTAssertEqual(try decode(#""future-theme""#), .system)
        XCTAssertEqual(try decode(#"{"name":1}"#), .system)
        XCTAssertEqual(String(data: try JSONEncoder().encode(PreviewTheme.navy), encoding: .utf8), #""system""#)
    }
}

// MARK: - PR #98 より前の版の設定の形

/// PR #98 より前（`b9bdc90^`）の `StoredEditorSettings`。保存データのうち、その版が読む項目の形を再現する。
private struct EarlierStoredSettings: Decodable {
    var app: EarlierAppSettings
    var folders: [String: FolderEditorSettings]
    var documents: [String: DocumentDisplayState]
    var bookmarks: [DocumentBookmark]?
}

/// PR #98 より前の `AppEditorSettings`。テーマ以外の項目の型はこの版と同じ。
private struct EarlierAppSettings: Decodable {
    var defaultMode: EditorMode
    var fontSize: Double
    var lineSpacing: Double
    var wrapsLines: Bool
    var imageImportMode: ImageImportMode?
    var fontChoice: EditorFontChoice?
    var horizontalMargin: Double?
    var verticalMargin: Double?
    var tabWidth: Int?
    var listIndentWidth: Int?
    var codeIndentWidth: Int?
    var tableAddsRowOnTab: Bool?
    var editorZoom: Double?
    var previewZoom: Double?
    var wordCountMode: WordCountMode?
    var readingEstimate: ReadingEstimateSettings?
    var disabledLintRules: Set<MarkdownLintRule>?
    var proofing: EditorProofingSettings?
    var showsFrontMatterInPreview: Bool?
    var formatsFrontMatterInPreview: Bool?
    var preservesSoftLineBreaksInPreview: Bool?
    var snippets: [EditorSnippet]?
    var loadsRemoteImages: Bool?
    var loadsExternalLinkPreviews: Bool?
    var showsMinimap: Bool?
    var usesInlineLivePresentation: Bool?
    var usesTypewriterMode: Bool?
    var terminologyEntries: [TerminologyEntry]?
    var terminologyOptions: TerminologyOptions?
    var attachmentDirectory: AttachmentDirectory?
    var markdownDialect: MarkdownDialect?
    var previewTheme: EarlierPreviewTheme?
    var editorTheme: EarlierPreviewTheme?
    var extensionPackages: [DeclarativeExtension]?
    var previewBodyWidth: Int?
    var showsInvisibleCharacters: Bool?
    var showsIndentGuides: Bool?
    var showsLineNumbers: Bool?
    var shortcutOverrides: [String: ShortcutChord]?
    var documentOpeningMode: DocumentOpeningMode?
}

/// PR #98 より前の `PreviewTheme`。知らないテーマ名で `DecodingError` を投げる。
private enum EarlierPreviewTheme: Decodable, Equatable {
    case system
    case paper
    case preset(PreviewThemePreset)
    case extensionTheme(DeclarativeExtension.Theme)

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let name = try? value.decode(String.self) {
            switch name {
            case "system": self = .system
            case "paper": self = .paper
            default:
                guard let preset = PreviewThemePreset(rawValue: name) else {
                    throw DecodingError.dataCorruptedError(in: value, debugDescription: "Unknown theme")
                }
                self = .preset(preset)
            }
        } else {
            self = .extensionTheme(try value.decode(DeclarativeExtension.Theme.self))
        }
    }
}
