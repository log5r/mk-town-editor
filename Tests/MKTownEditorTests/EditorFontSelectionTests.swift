import AppKit
import XCTest
@testable import MKTownEditor

/// エディタのフォントの選択（Issue #103）。docs/editor-font-selection.md
@MainActor
final class EditorFontSelectionTests: XCTestCase {
    private static let missingFamily = "MKTown Missing Font 7c1e9a"

    // MARK: - 保存値の互換

    func testSettingsSavedByEarlierVersionsKeepTheirBuiltInFont() throws {
        for choice in EditorFontChoice.allCases {
            let defaults = isolatedDefaults()
            let old = #"{"app":{"defaultMode":"split","fontSize":15,"lineSpacing":3,"wrapsLines":true,"#
                + #""fontChoice":"\#(choice.rawValue)"},"folders":{},"documents":{}}"#
            defaults.set(Data(old.utf8), forKey: "MKTownEditor.editorSettings.v1")
            let store = EditorSettingsStore(defaults: defaults, prunesMissingDocuments: false)
            XCTAssertEqual(store.app.fontSize, 15, "the old settings were dropped instead of read")
            XCTAssertNil(store.app.fontFamily)
            XCTAssertEqual(store.app.editorFont, .builtIn(choice))
            XCTAssertEqual(store.textStyle(for: nil).font, .builtIn(choice))
        }
    }

    func testSettingsWithoutAnyFontUseSystemMonospaced() throws {
        let data = Data(#"{"defaultMode":"split","fontSize":13,"lineSpacing":3,"wrapsLines":true}"#.utf8)
        let decoded = try JSONDecoder().decode(AppEditorSettings.self, from: data)
        XCTAssertEqual(decoded.editorFont, .default)
        XCTAssertEqual(EditorFont.default, .builtIn(.monospacedSystem))
    }

    /// 以前の版は `fontFamily` を知らない。保存した値を以前の版の形で読んでも、
    /// `fontChoice` が以前の版の選択肢のまま読めることを確かめる（設定全体の読み込みに失敗しない）。
    func testChoosingAFamilyKeepsAValueEarlierVersionsCanRead() throws {
        struct EarlierVersionSettings: Decodable {
            var fontSize: Double
            var fontChoice: EditorFontChoice?
        }
        var app = AppEditorSettings()
        app.editorFont = .builtIn(.menlo)
        app.editorFont = .family("Hiragino Sans")
        XCTAssertEqual(app.fontFamily, "Hiragino Sans")
        XCTAssertEqual(app.fontChoice, .menlo, "the earlier version falls back to the last built-in choice")

        let data = try JSONEncoder().encode(app)
        let earlier = try JSONDecoder().decode(EarlierVersionSettings.self, from: data)
        XCTAssertEqual(earlier.fontChoice, .menlo)
        XCTAssertEqual(try JSONDecoder().decode(AppEditorSettings.self, from: data).editorFont,
                       .family("Hiragino Sans"))
    }

    func testChoosingABuiltInFontClearsTheFamily() {
        var app = AppEditorSettings()
        app.editorFont = .family("Hiragino Sans")
        app.editorFont = .builtIn(.system)
        XCTAssertNil(app.fontFamily)
        XCTAssertEqual(app.fontChoice, .system)
        XCTAssertEqual(app.editorFont, .builtIn(.system))
    }

    func testEmptyFamilyNameReadsAsTheBuiltInChoice() {
        var app = AppEditorSettings()
        app.fontChoice = .menlo
        app.fontFamily = ""
        XCTAssertEqual(app.editorFont, .builtIn(.menlo))
        app.editorFont = .family("")
        XCTAssertNil(app.fontFamily)
    }

    func testChosenFamilyPersistsAndReachesTheTextStyle() {
        let defaults = isolatedDefaults()
        let store = EditorSettingsStore(defaults: defaults, prunesMissingDocuments: false)
        var app = store.app
        app.editorFont = .family("Hiragino Mincho ProN")
        store.setAppSettings(app)

        let restored = EditorSettingsStore(defaults: defaults, prunesMissingDocuments: false)
        XCTAssertEqual(restored.app.editorFont, .family("Hiragino Mincho ProN"))
        let document = URL(fileURLWithPath: "/tmp/work/README.md")
        XCTAssertEqual(restored.textStyle(for: document).font, .family("Hiragino Mincho ProN"))
        XCTAssertEqual(restored.textStyle(for: nil).font, .family("Hiragino Mincho ProN"))
    }

    // MARK: - フォントの解決

    func testInstalledFamilyResolvesToARegularFaceOfThatFamily() throws {
        let font = EditorFont.family("Menlo")
        XCTAssertTrue(font.isAvailable)
        let resolved = font.font(size: 15)
        XCTAssertEqual(resolved.familyName, "Menlo")
        XCTAssertEqual(resolved.pointSize, 15)
        XCTAssertFalse(resolved.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertFalse(resolved.fontDescriptor.symbolicTraits.contains(.italic))
    }

    func testMissingFamilyFallsBackToTheDefaultFontWithoutLosingTheSetting() throws {
        let missing = EditorFont.family(Self.missingFamily)
        XCTAssertFalse(missing.isAvailable)
        let resolved = missing.font(size: 17)
        let expected = EditorFont.default.font(size: 17)
        XCTAssertEqual(resolved.fontName, expected.fontName)
        XCTAssertEqual(resolved.pointSize, 17)

        let defaults = isolatedDefaults()
        let store = EditorSettingsStore(defaults: defaults, prunesMissingDocuments: false)
        var app = store.app
        app.editorFont = missing
        store.setAppSettings(app)
        let restored = EditorSettingsStore(defaults: defaults, prunesMissingDocuments: false)
        XCTAssertEqual(restored.app.editorFont, missing, "the setting is kept so the font returns when reinstalled")

        let view = EditorTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        restored.textStyle(for: nil).apply(to: view)
        XCTAssertEqual(view.font?.fontName, expected.fontName)
    }

    func testTitlesUseBuiltInNamesAndLocalizedFamilyNames() {
        XCTAssertEqual(EditorFont.builtIn(.menlo).title, "Menlo")
        XCTAssertEqual(EditorFont.family("Menlo").title, "Menlo")
        XCTAssertEqual(EditorFont.family("Hiragino Sans").title,
                       NSFontManager.shared.localizedName(forFamily: "Hiragino Sans", face: nil))
    }

    /// 本文フォントは入力属性と段落の既定のタブ幅にも反映される。日本語の後に挿入する記号は
    /// 入力属性のフォントを使う（docs/editor-fallback-font-inheritance.md）ため、選んだフォントがそこに入っていること。
    func testApplyingAFamilySetsTheBodyAndTypingFonts() throws {
        let view = EditorTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.isRichText = false
        view.string = "日本語のあとに - text"
        EditorTextStyle(font: .family("Hiragino Sans"), fontSize: 14, tabWidth: 4).apply(to: view)

        XCTAssertEqual(view.font?.familyName, "Hiragino Sans")
        let typing = try XCTUnwrap(view.typingAttributes[.font] as? NSFont)
        XCTAssertEqual(typing.familyName, "Hiragino Sans")
        XCTAssertEqual(typing.pointSize, 14)
        let space = (" " as NSString).size(withAttributes: [.font: typing]).width
        XCTAssertEqual(view.defaultParagraphStyle?.defaultTabInterval ?? 0, space * 4, accuracy: 0.01)
    }

    // MARK: - 設定画面の選択肢

    func testInstalledFamiliesAreSortedUniqueAndMarkMonospacedFamilies() throws {
        let families = EditorFontFamily.installed()
        XCTAssertFalse(families.isEmpty)
        XCTAssertEqual(Set(families.map(\.name)).count, families.count, "each family is listed once")
        XCTAssertFalse(families.contains { $0.name.hasPrefix(".") }, "hidden system families are not listed")
        for (earlier, later) in zip(families, families.dropFirst()) {
            XCTAssertNotEqual(earlier.displayName.localizedStandardCompare(later.displayName), .orderedDescending,
                              "\(earlier.displayName) before \(later.displayName)")
        }
        let menlo = try XCTUnwrap(families.first { $0.name == "Menlo" })
        XCTAssertTrue(menlo.isMonospaced)
        let helvetica = try XCTUnwrap(families.first { $0.name == "Helvetica" })
        XCTAssertFalse(helvetica.isMonospaced)
        for family in families.prefix(20) {
            XCTAssertTrue(EditorFont.family(family.name).isAvailable, family.name)
        }
    }

    func testOptionsSplitMonospacedFamiliesAndKeepAnUnlistedSelection() {
        let installed = [
            EditorFontFamily(name: "Helvetica", displayName: "Helvetica", isMonospaced: false),
            EditorFontFamily(name: "Menlo", displayName: "Menlo", isMonospaced: true),
        ]
        let builtIn = EditorFontOptions(installed: installed, selected: .default)
        XCTAssertEqual(builtIn.monospaced.map(\.name), ["Menlo"])
        XCTAssertEqual(builtIn.proportional.map(\.name), ["Helvetica"])
        XCTAssertNil(builtIn.unlistedFamily)
        XCTAssertFalse(builtIn.isMissing)

        let listed = EditorFontOptions(installed: installed, selected: .family("Menlo"))
        XCTAssertNil(listed.unlistedFamily)
        XCTAssertFalse(listed.isMissing)

        let missing = EditorFontOptions(installed: installed, selected: .family(Self.missingFamily))
        XCTAssertEqual(missing.unlistedFamily, Self.missingFamily)
        XCTAssertTrue(missing.isMissing)

        // 一覧を読み込む前は見つからないと判断しない。
        let loading = EditorFontOptions(installed: [], selected: .family("Menlo"))
        XCTAssertEqual(loading.unlistedFamily, "Menlo")
        XCTAssertFalse(loading.isMissing)
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "EditorFontSelectionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
}
