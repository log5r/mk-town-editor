import AppKit
import SwiftUI
import XCTest
@testable import MKTownEditor

/// エディタのフォントの選択（Issue #103）。docs/editor-font-selection.md
@MainActor
final class EditorFontSelectionTests: XCTestCase {
    fileprivate static let missingFamily = "MKTown Missing Font 7c1e9a"

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

    // MARK: - フォントの追加・削除への追従（#103 のレビュー指摘）

    /// 「フォントが無い → 使えるようになる」「使える → 無くなる」のどちらでも、同じエディタが
    /// スタイルを適用し直し、行番号も新しい本文フォントの行の高さに従う。スタイルの値は変わらないため、
    /// 以前は `MarkdownTextEditor.updateNSView` の比較で適用が省かれ、代替フォントのまま残っていた。
    func testOpenEditorFollowsTheChosenFamilyBeingInstalledAndRemoved() throws {
        var installed: NSFont?
        let (scrollView, view) = makeEditorWithRuler()
        view.fontResolver = EditorFontResolver { name, size in
            name == Self.missingFamily ? installed.map { NSFontManager.shared.convert($0, toSize: size) } : nil
        }
        view.string = "1行目\n- 2\n"
        EditorTextStyle(font: .family(Self.missingFamily), fontSize: 15).apply(to: view)
        let fallback = EditorFont.default.font(size: 15)
        XCTAssertEqual(view.font?.fontName, fallback.fontName, "a missing family uses the default font")

        installed = try XCTUnwrap(NSFont(name: "Menlo-Regular", size: 15))
        NotificationCenter.default.post(name: NSFont.fontSetChangedNotification, object: nil)
        try assertBodyFont(of: view, in: scrollView, is: "Menlo-Regular", size: 15)

        installed = nil
        NotificationCenter.default.post(name: NSFont.fontSetChangedNotification, object: nil)
        try assertBodyFont(of: view, in: scrollView, is: fallback.fontName, size: 15)
        XCTAssertEqual(view.string, "1行目\n- 2\n")
    }

    /// 解決する書体が変わらない通知では適用し直さない。標準装備のフォントは通知を受けても変わらない。
    func testFontSetChangesWithoutANewResolutionLeaveTheEditorAlone() throws {
        let (_, view) = makeEditorWithRuler()
        var resolved: NSFont? = NSFont(name: "Menlo-Regular", size: 13)
        view.fontResolver = EditorFontResolver { _, _ in resolved }
        EditorTextStyle(font: .family("Menlo")).apply(to: view)
        let applied = try XCTUnwrap(view.appliedBodyFont)
        XCTAssertFalse(view.reapplyTextStyleIfFontResolutionChanged(), "same face, no relayout")
        XCTAssertTrue(view.appliedBodyFont === applied)

        EditorTextStyle(font: .builtIn(.system)).apply(to: view)
        resolved = nil
        XCTAssertFalse(view.reapplyTextStyleIfFontResolutionChanged())
        NotificationCenter.default.post(name: NSFont.fontSetChangedNotification, object: nil)
        XCTAssertEqual(view.font?.fontName, NSFont.systemFont(ofSize: 13).fontName)
    }

    /// 実際の編集画面（`MarkdownTextEditor`）でも、通知を受けたら本文と行番号が追従し、
    /// その後のSwiftUIの更新で元に戻らない。`textView.font` は先頭の文字のフォントを返すので、
    /// 本文は英字で始めて英字で終える（日本語には代替フォントが付く）。
    func testHostedEditorFollowsFontSetChanges() async throws {
        final class Box: ObservableObject { @Published var text = "Body 本文\nline 2" }
        struct Host: View {
            @ObservedObject var box: Box
            let model: MarkdownEditorModel
            var body: some View {
                MarkdownTextEditor(text: $box.text, model: model,
                                   textStyle: EditorTextStyle(font: .family(EditorFontSelectionTests.missingFamily),
                                                              fontSize: 14))
            }
        }
        let box = Box()
        let host = NSHostingView(rootView: Host(box: box, model: MarkdownEditorModel()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        let view = try XCTUnwrap(findEditor(in: host))
        let scrollView = try XCTUnwrap(view.enclosingScrollView)
        XCTAssertEqual(view.font?.fontName, EditorFont.default.font(size: 14).fontName)

        var installed: NSFont? = NSFont(name: "Menlo-Regular", size: 14)
        view.fontResolver = EditorFontResolver { name, size in
            name == Self.missingFamily ? installed.map { NSFontManager.shared.convert($0, toSize: size) } : nil
        }
        NotificationCenter.default.post(name: NSFont.fontSetChangedNotification, object: nil)
        try assertBodyFont(of: view, in: scrollView, is: "Menlo-Regular", size: 14)

        box.text = "Body 本文\nline 2\nline 3"
        for _ in 0..<5 where view.string != box.text {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(view.string, box.text)
        XCTAssertEqual(view.font?.fontName, "Menlo-Regular", "a SwiftUI update must not restore the fallback")

        installed = nil
        NotificationCenter.default.post(name: NSFont.fontSetChangedNotification, object: nil)
        try assertBodyFont(of: view, in: scrollView, is: EditorFont.default.font(size: 14).fontName, size: 14)
    }

    private func makeEditorWithRuler() -> (NSScrollView, EditorTextView) {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let view = EditorTextView(frame: scrollView.bounds)
        view.isRichText = false
        scrollView.documentView = view
        scrollView.verticalRulerView = MarkdownLineNumberRulerView(scrollView: scrollView, editor: view)
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        return (scrollView, view)
    }

    private func assertBodyFont(of view: EditorTextView, in scrollView: NSScrollView, is name: String,
                                size: CGFloat, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(view.font?.fontName, name, file: file, line: line)
        XCTAssertEqual(view.font?.pointSize, size, file: file, line: line)
        XCTAssertEqual(view.appliedBodyFont?.fontName, name, file: file, line: line)
        let typing = try XCTUnwrap(view.typingAttributes[.font] as? NSFont, file: file, line: line)
        XCTAssertEqual(typing.fontName, name, "inserted symbols use the typing font", file: file, line: line)
        let manager = try XCTUnwrap(view.layoutManager)
        let container = try XCTUnwrap(view.textContainer)
        manager.ensureLayout(for: container)
        if !view.string.isEmpty {
            let stored = try XCTUnwrap(view.textStorage?.attribute(.font, at: view.string.utf16.count - 1,
                                                                   effectiveRange: nil) as? NSFont)
            XCTAssertEqual(stored.fontName, name, "existing text is restyled", file: file, line: line)
        }
        let expected = manager.defaultLineHeight(for: try XCTUnwrap(view.font))
        let labels = MarkdownLineNumberLayout.labels(in: view, visibleRect: view.bounds)
        XCTAssertFalse(labels.isEmpty, file: file, line: line)
        for label in labels {
            XCTAssertEqual(label.height, expected, accuracy: 0.01, "line numbers follow the body font",
                           file: file, line: line)
        }
        XCTAssertTrue(scrollView.verticalRulerView is MarkdownLineNumberRulerView, file: file, line: line)
    }

    private func findEditor(in view: NSView) -> EditorTextView? {
        if let editor = view as? EditorTextView { return editor }
        return view.subviews.lazy.compactMap { self.findEditor(in: $0) }.first
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
