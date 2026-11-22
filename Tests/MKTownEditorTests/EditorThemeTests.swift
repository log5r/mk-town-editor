import AppKit
import SwiftUI
import XCTest
@testable import MKTownEditor

@MainActor
final class EditorThemeTests: XCTestCase {
    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "EditorThemeTests." + UUID().uuidString
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    // MARK: - 設定

    func testUnsavedSettingsUseNavyEditorThemeAndKeepPreviewDefault() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = EditorSettingsStore(defaults: defaults, prunesMissingDocuments: false, appearance: .light)

        XCTAssertNil(store.app.editorTheme)
        XCTAssertFalse(store.app.followsAppearance(for: .editor), "外観に合わせた切り替えは既定でオフ")
        XCTAssertFalse(store.app.followsAppearance(for: .preview))
        // 切り替えがオフなら、外観によらず既定の「紺色」。
        for appearance in [InterfaceAppearance.light, .dark] {
            store.updateAppearance(appearance)
            XCTAssertEqual(store.editorTheme, .navy)
            XCTAssertEqual(store.editorTheme.colorScheme, .dark)
            let palette = EditorThemePalette(theme: store.editorTheme)
            XCTAssertEqual(palette.appearanceName, .darkAqua)
            XCTAssertEqual(palette.background, DeclarativeExtension.Theme.parse("#283264"))
            // プレビューの既定は従来どおり「システム」。
            XCTAssertEqual(store.previewTheme, .system)
        }
        XCTAssertNil(store.app.previewTheme)
    }

    /// 以前の版で保存した設定（新しい項目なし）を読む。編集画面の「システム」と未設定は「紺色」になり、
    /// 明示的に選んだテーマはそのまま残る。保存データは書き換えない。
    func testLegacyEditorThemeValuesAreReadAsNavy() throws {
        func decode(_ editorTheme: String?) throws -> AppEditorSettings {
            let field = editorTheme.map { ",\"editorTheme\":\"\($0)\"" } ?? ""
            return try JSONDecoder().decode(AppEditorSettings.self, from: Data(
                "{\"defaultMode\":\"split\",\"fontSize\":13,\"lineSpacing\":3,\"wrapsLines\":true\(field)}".utf8))
        }
        let legacySystem = try decode("system")
        XCTAssertEqual(legacySystem.editorTheme, .system, "保存値は書き換えない")
        XCTAssertNil(legacySystem.editorThemeFollowsAppearance)
        XCTAssertNil(legacySystem.previewThemeFollowsAppearance)
        for appearance in [InterfaceAppearance.light, .dark] {
            XCTAssertEqual(legacySystem.theme(for: .editor, appearance: appearance), .navy)
            XCTAssertEqual(try decode(nil).theme(for: .editor, appearance: appearance), .navy)
            XCTAssertEqual(try decode("github-dark").theme(for: .editor, appearance: appearance), .preset(.githubDark))
            // プレビューの「システム」は「紺色」に置き換えない。
            XCTAssertEqual(legacySystem.theme(for: .preview, appearance: appearance), .system)
        }
        // 設定画面の選択状態も「紺色」になる。
        XCTAssertEqual(legacySystem.theme(for: .editor, slot: .fixed), .navy)

        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("{\"app\":{\"defaultMode\":\"split\",\"fontSize\":13,\"lineSpacing\":3,\"wrapsLines\":true,\"editorTheme\":\"system\"},\"folders\":{},\"documents\":{}}".utf8),
                     forKey: "MKTownEditor.editorSettings.v1")
        let store = EditorSettingsStore(defaults: defaults, prunesMissingDocuments: false, appearance: .dark)
        XCTAssertEqual(store.app.editorTheme, .system)
        XCTAssertEqual(store.editorTheme, .navy)
        XCTAssertEqual(EditorThemePalette(theme: store.editorTheme), .navy)
    }

    func testNavyIsStoredByNameAndOfferedOnlyForEditor() throws {
        var settings = AppEditorSettings()
        settings.editorTheme = .navy
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(settings), encoding: .utf8))
        XCTAssertTrue(json.contains("\"editorTheme\":\"navy\""), json)
        XCTAssertEqual(try JSONDecoder().decode(AppEditorSettings.self, from: Data(json.utf8)).editorTheme, .navy)
        XCTAssertEqual(PreviewTheme.navy.title, "紺色")

        // 編集画面の選択肢は紺色が先頭で「システム」がない。プレビューは「システム」が先頭で「紺色」がない。
        XCTAssertEqual(ThemeTarget.editor.basicThemes, [.navy, .paper])
        XCTAssertEqual(ThemeTarget.preview.basicThemes, [.system, .paper])
        XCTAssertFalse(ThemeTarget.editor.basicThemes.contains(.system))
        XCTAssertFalse(ThemeTarget.preview.basicThemes.contains(.navy))
        XCTAssertFalse(PreviewThemeOptions.presetThemes.contains(.navy))
        XCTAssertFalse(PreviewThemeOptions.presetThemes.contains(.system))
    }

    func testEditorThemePersistsIndependentlyOfPreviewTheme() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = EditorSettingsStore(defaults: defaults, prunesMissingDocuments: false)
        var settings = store.app
        settings.editorTheme = .preset(.nord)
        store.setAppSettings(settings)

        let reopened = EditorSettingsStore(defaults: defaults, prunesMissingDocuments: false)
        XCTAssertEqual(reopened.app.editorTheme, .preset(.nord))
        XCTAssertEqual(reopened.app.theme(for: .editor, slot: .fixed), .preset(.nord))
        XCTAssertNil(reopened.app.previewTheme)

        // 明示的に選んだ以前の既定（GitHub風（ダーク））は、新しい既定の「紺色」に置き換わらない。
        settings = reopened.app
        settings.editorTheme = .preset(.githubDark)
        reopened.setAppSettings(settings)
        XCTAssertEqual(EditorSettingsStore(defaults: defaults, prunesMissingDocuments: false)
            .app.theme(for: .editor, slot: .fixed), .preset(.githubDark))
    }

    func testEditorThemeIsStoredWithTheSameEncodingAsPreviewTheme() throws {
        var settings = AppEditorSettings()
        settings.editorTheme = .preset(.tomorrowNight)
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(settings), encoding: .utf8))
        XCTAssertTrue(json.contains("\"editorTheme\":\"tomorrow-night\""), json)
        // 以前の版で保存した設定（項目なし）は未設定として読む。
        let legacy = try JSONDecoder().decode(AppEditorSettings.self, from: Data("{\"defaultMode\":\"split\",\"fontSize\":13,\"lineSpacing\":3,\"wrapsLines\":true}".utf8))
        XCTAssertNil(legacy.editorTheme)
        XCTAssertEqual(legacy.theme(for: .editor, slot: .fixed), EditorThemePalette.defaultTheme)
    }

    func testExtensionThemeCanBeSelectedForEditorAndIsResetOnRemoval() throws {
        let theme = PreviewThemePreset.nord.theme
        var package = try JSONDecoder().decode(DeclarativeExtension.self, from: Data(
            "{\"schemaVersion\":1,\"id\":\"example.theme\",\"name\":\"Example\"}".utf8))
        package.theme = theme
        var settings = AppEditorSettings()
        settings.installExtension(package, selectingThemeFor: \.editorTheme)
        XCTAssertEqual(settings.editorTheme, .extensionTheme(theme))
        XCTAssertNil(settings.previewTheme, "選んだ側の配色だけを変える")

        settings.installExtension(package, selectingThemeFor: \.previewTheme)
        XCTAssertEqual(settings.previewTheme, .extensionTheme(theme))

        // 同じ id で読み込み直すと、両方の選択が新しいテーマに移る。
        var updated = theme
        updated.name = "Example 2"
        package.theme = updated
        settings.installExtension(package)
        XCTAssertEqual(settings.editorTheme, .extensionTheme(updated))
        XCTAssertEqual(settings.previewTheme, .extensionTheme(updated))
        XCTAssertEqual(settings.extensionPackages?.count, 1)

        settings.removeExtension("example.theme")
        XCTAssertNil(settings.editorTheme, "編集画面は既定の「紺色」に戻る")
        XCTAssertEqual(settings.previewTheme, .system)
        XCTAssertEqual(settings.extensionPackages, [])
    }

    // MARK: - 配色

    func testEveryThemeGivesReadableEditorColors() throws {
        for theme in PreviewTheme.allCases {
            let palette = EditorThemePalette(theme: theme)
            let background = palette.background
            XCTAssertEqual(palette.background, theme.editorColors.background, theme.title)
            XCTAssertEqual(palette.appearanceName, theme.editorColors.colorScheme == .dark ? .darkAqua : .aqua,
                           theme.title)
            let roles: [MarkdownSyntaxSpan.Role] = [.heading, .code, .link, .marker, .quoteMarker, .listMarker,
                                                    .taskMarker, .tableMarker] +
                CodeSyntaxToken.allCases.map(MarkdownSyntaxSpan.Role.codeToken)
            for color in [palette.text, palette.lineNumber] + roles.map(palette.color(for:)) {
                XCTAssertGreaterThanOrEqual(PreviewTypography.contrastRatio(color, background), 4.5, theme.title)
            }
            let selection = palette.selection
            XCTAssertGreaterThanOrEqual(PreviewTypography.contrastRatio(palette.text, selection), 4.5, theme.title)
            // 標準のテーマでは本文の色が選択色に対しても読めるため、補正されない。
            XCTAssertEqual(palette.selectedText, palette.text, theme.title)
            XCTAssertEqual(palette.selectedTextAttributes[.foregroundColor] as? NSColor, palette.selectedText)
            XCTAssertEqual(palette.insertionPoint, palette.text)
            // 見出しは本文と区別できる色にする。
            XCTAssertNotEqual(palette.heading, palette.text, theme.title)
        }
    }

    func testThemeColorsAreKeptWhenReadableAndUsedForEditorRoles() throws {
        let palette = EditorThemePalette(theme: .preset(.githubDark))
        let theme = PreviewThemePreset.githubDark.theme
        XCTAssertEqual(palette.text, theme.color(\.body))
        // GitHub風は見出しの色が本文と同じため、リンク色で見出しを区別する。
        XCTAssertEqual(palette.heading, theme.color(\.link))
        XCTAssertEqual(palette.link, theme.color(\.link))
        XCTAssertEqual(palette.code, theme.syntaxColor(for: .string))
        XCTAssertEqual(palette.marker, theme.syntaxColor(for: .comment))
        XCTAssertEqual(palette.lineNumber, theme.syntaxColor(for: .comment))
        XCTAssertEqual(palette.color(for: .codeToken(.keyword)), theme.syntaxColor(for: .keyword))
        XCTAssertEqual(palette.color(for: .taskMarker), theme.syntaxColor(for: .inserted))

        // 見出しの色を持つテーマはそれを使う。
        XCTAssertEqual(EditorThemePalette(theme: .preset(.dracula)).heading,
                       PreviewThemePreset.dracula.theme.color(\.heading))
    }

    func testLowContrastThemeColorsAreAdjustedForEditorBackground() throws {
        // Draculaのコメント色はコード背景（#21222C）では4.5:1を満たすが、編集画面の背景（#282A36）では届かない。
        let background = try XCTUnwrap(DeclarativeExtension.Theme.parse("#282A36"))
        let comment = try XCTUnwrap(DeclarativeExtension.Theme.parse("#7B89B3"))
        XCTAssertLessThan(PreviewTypography.contrastRatio(comment, background), 4.5)
        let adjusted = EditorThemePalette.readable(comment, on: background)
        XCTAssertGreaterThanOrEqual(PreviewTypography.contrastRatio(adjusted, background), 4.5)
        XCTAssertNotEqual(adjusted, comment)
        XCTAssertEqual(EditorThemePalette(theme: .preset(.dracula)).marker, adjusted)

        let white = try XCTUnwrap(DeclarativeExtension.Theme.parse("#FFFFFF"))
        let light = try XCTUnwrap(DeclarativeExtension.Theme.parse("#9A9A9A"))
        let darkened = EditorThemePalette.readable(light, on: white)
        XCTAssertGreaterThanOrEqual(PreviewTypography.contrastRatio(darkened, white), 4.5)
        XCTAssertLessThan(darkened.usingColorSpace(.sRGB)!.redComponent, light.usingColorSpace(.sRGB)!.redComponent)

        let readable = try XCTUnwrap(DeclarativeExtension.Theme.parse("#1F2328"))
        XCTAssertEqual(EditorThemePalette.readable(readable, on: white), readable)
    }

    func testCustomThemeWithoutSyntaxColorsUsesCodeColorForTokens() throws {
        let theme = DeclarativeExtension.Theme(
            name: "Plain", background: "#FFFFFF", body: "#1F2328", heading: "#1F2328",
            code: "#5A1E5A", link: "#0969DA", codeBackground: "#F6F8FA")
        let palette = EditorThemePalette(theme: .extensionTheme(theme))
        let code = try XCTUnwrap(theme.color(\.code))
        XCTAssertEqual(palette.code, code)
        for token in CodeSyntaxToken.allCases {
            XCTAssertEqual(palette.color(for: .codeToken(token)), code, token.rawValue)
        }
        // 字句の色がないテーマでは、記号は本文の色になる。
        XCTAssertEqual(palette.marker, theme.color(\.body))
    }

    /// PR #92のレビュー指摘の再発防止。本文の色が背景には足りても、リンク色を混ぜた選択色には足りないテーマがある。
    func testSelectedTextStaysReadableOnDerivedSelectionBackground() throws {
        let theme = DeclarativeExtension.Theme(
            name: "Gray Body", background: "#FFFFFF", body: "#767676", heading: "#000000",
            code: "#000000", link: "#000000", codeBackground: "#FFFFFF")
        XCTAssertNoThrow(try theme.validate())
        let palette = EditorThemePalette(theme: .extensionTheme(theme))
        let selection = palette.selection
        // 本文の色は背景には足りるが、選択色には足りない。
        XCTAssertGreaterThanOrEqual(PreviewTypography.contrastRatio(palette.text, palette.background), 4.5)
        XCTAssertLessThan(PreviewTypography.contrastRatio(palette.text, selection), 4.5)
        XCTAssertGreaterThanOrEqual(PreviewTypography.contrastRatio(palette.selectedText, selection), 4.5)
        XCTAssertEqual(palette.selectedTextAttributes[.foregroundColor] as? NSColor, palette.selectedText)
        XCTAssertEqual(palette.selectedTextAttributes[.backgroundColor] as? NSColor, selection)
    }

    /// 「紺色」は紺（#283264）の背景を変えず、着色した文字を背景に対して7:1以上の明るい色にする（Issue #99）。
    /// macOSの外観によらずダークの外観で表示する。
    func testNavyPaletteKeepsNavyBackgroundAndUsesBrightColors() throws {
        let palette = EditorThemePalette(theme: .navy)
        let github = PreviewThemePreset.githubDark.theme
        let definition = PreviewTheme.navyDefinition
        let navy = try XCTUnwrap(DeclarativeExtension.Theme.parse("#283264"))
        XCTAssertEqual(palette, .navy)
        XCTAssertEqual(palette.theme, .navy)
        XCTAssertEqual(palette.background, navy)
        XCTAssertEqual(palette.appearanceName, .darkAqua)
        XCTAssertEqual(palette.text, github.color(\.body))
        XCTAssertEqual(palette.insertionPoint, palette.text)

        // Issue #99の再現条件：GitHub風（ダーク）のリンク・キーワード・コメントの色は、紺の背景で7:1に届かない。
        for color in [github.color(\.link), github.syntaxColor(for: .keyword), github.syntaxColor(for: .comment)] {
            XCTAssertLessThan(PreviewTypography.contrastRatio(try XCTUnwrap(color), navy),
                              PreviewTheme.navyMinimumContrast)
        }
        // 見出しとリンクは明るい水色。定義の色がそのまま使われ、明度の補正（白へ寄せる処理）に頼らない。
        let link = try XCTUnwrap(DeclarativeExtension.Theme.parse("#7ADCFF"))
        XCTAssertEqual(palette.link, link)
        XCTAssertEqual(palette.heading, link, "見出しは本文と区別できるリンク色にする")
        XCTAssertEqual(palette.marker, definition.syntaxColor(for: .comment))
        XCTAssertEqual(palette.lineNumber, definition.syntaxColor(for: .comment))
        XCTAssertEqual(palette.color(for: .listMarker), definition.syntaxColor(for: .keyword))
        for token in CodeSyntaxToken.allCases {
            XCTAssertEqual(palette.color(for: .codeToken(token)), definition.syntaxColor(for: token), "\(token)")
        }
        // 7:1に届いていた字句の色はGitHub風（ダーク）のまま使う。
        for token in [CodeSyntaxToken.string, .attribute, .inserted, .deleted] {
            XCTAssertEqual(definition.syntaxColor(for: token), github.syntaxColor(for: token), "\(token)")
        }

        let roles: [MarkdownSyntaxSpan.Role] = [.heading, .code, .link, .marker, .quoteMarker, .listMarker,
                                                .taskMarker, .tableMarker] +
            CodeSyntaxToken.allCases.map(MarkdownSyntaxSpan.Role.codeToken)
        for (role, color) in zip(roles, roles.map(palette.color(for:))) {
            XCTAssertGreaterThanOrEqual(PreviewTypography.contrastRatio(color, navy),
                                        PreviewTheme.navyMinimumContrast, "\(role)")
            // 着色した文字は本文と区別できる色のままにする（白に寄せすぎない）。
            XCTAssertNotEqual(color, palette.text, "\(role)")
        }
        XCTAssertGreaterThanOrEqual(PreviewTypography.contrastRatio(palette.lineNumber, navy),
                                    PreviewTheme.navyMinimumContrast)
        XCTAssertGreaterThanOrEqual(PreviewTypography.contrastRatio(palette.selectedText, palette.selection), 4.5)
        XCTAssertEqual(palette.selectedText, palette.text, "明るいリンク色を混ぜた選択色でも本文を補正しない")
        XCTAssertEqual(palette.selectedTextAttributes[.backgroundColor] as? NSColor, palette.selection)

        // 外観がライトでも同じ紺の配色になる（動的な色を使わない）。
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        var resolved: NSColor?
        light.performAsCurrentDrawingAppearance { resolved = palette.background.usingColorSpace(.sRGB) }
        XCTAssertEqual(resolved, navy)
    }

    /// 以前の版で編集画面に保存した「システム」は、「紺色」と同じ配色で表示する。
    func testSystemEditorThemeUsesNavyPalette() throws {
        let navy = EditorThemePalette(theme: .navy)
        let palette = EditorThemePalette(theme: .system)
        let roles: [MarkdownSyntaxSpan.Role] = [.heading, .code, .link, .marker, .quoteMarker, .listMarker,
                                                .taskMarker, .tableMarker] +
            CodeSyntaxToken.allCases.map(MarkdownSyntaxSpan.Role.codeToken)
        XCTAssertEqual(palette, .navy)
        XCTAssertEqual(palette.background, navy.background)
        XCTAssertEqual(palette.text, navy.text)
        XCTAssertEqual(palette.selection, navy.selection)
        XCTAssertEqual(palette.selectedText, navy.selectedText)
        XCTAssertEqual(palette.insertionPoint, navy.insertionPoint)
        XCTAssertEqual(palette.lineNumber, navy.lineNumber)
        XCTAssertEqual(palette.appearanceName, .darkAqua)
        for role in roles {
            XCTAssertEqual(palette.color(for: role), navy.color(for: role), "\(role)")
        }
    }

    /// 編集画面の隣のミニマップも、「紺色」では紺の背景とダークの外観にそろえる。以前の「システム」も同じ。
    func testNavyEditorSurfaceUsesNavyColors() {
        XCTAssertEqual(PreviewTheme.navy.background, DeclarativeExtension.Theme.parse("#283264"))
        XCTAssertEqual(PreviewTheme.navy.colorScheme, .dark)
        XCTAssertEqual(PreviewTheme.system.editorColors, .navy)
        XCTAssertEqual(PreviewTheme.system.editorColors.background, DeclarativeExtension.Theme.parse("#283264"))
        XCTAssertEqual(PreviewTheme.system.editorColors.colorScheme, .dark)
        // プレビュー用の「システム」の色は従来どおり定めない（文字色はmacOSの色に従う）。
        XCTAssertNil(PreviewTheme.system.background)
        XCTAssertNil(PreviewTheme.system.bodyColor)
        // 「システム」以外のテーマは編集画面でもそのテーマの色を使う。
        XCTAssertEqual(PreviewTheme.preset(.nord).editorColors, .preset(.nord))
    }

    func testHighlighterUsesPaletteColors() {
        let view = NSTextView()
        view.string = "# Title"
        let palette = EditorThemePalette(theme: .preset(.tomorrowNight))
        MarkdownSyntaxHighlighter.apply(to: view, palette: palette)
        XCTAssertEqual(color(at: 2, in: view), palette.heading)
        MarkdownSyntaxHighlighter.apply(to: view)
        XCTAssertEqual(color(at: 2, in: view), EditorThemePalette.navy.heading)
    }

    func testCoordinatorRecolorsSameSourceWhenPaletteChanges() {
        let view = NSTextView()
        view.string = "# Title\n\n```js\nconst a = 1\n```"
        let keyword = (view.string as NSString).range(of: "const").location
        let coordinator = MarkdownTextEditor.Coordinator(text: .constant(view.string), model: MarkdownEditorModel())
        coordinator.textView = view
        coordinator.refreshSyntax()
        XCTAssertEqual(color(at: 2, in: view), EditorThemePalette.navy.heading)

        let palette = EditorThemePalette(theme: .preset(.dracula))
        coordinator.palette = palette
        coordinator.refreshSyntax()
        XCTAssertEqual(color(at: 2, in: view), palette.heading)
        // Tree-sitterで解析するJavaScriptの字句も新しい配色で塗り直す。
        XCTAssertEqual(color(at: keyword, in: view), palette.color(for: .codeToken(.keyword)))
    }

    // MARK: - 編集画面への反映

    private struct Host: View {
        @ObservedObject var settings: EditorSettingsStore
        @Binding var text: String
        let model: MarkdownEditorModel

        var body: some View {
            MarkdownTextEditor(text: $text, model: model, theme: settings.editorTheme)
        }
    }

    private final class Window {
        let window: NSWindow
        let host: NSHostingView<Host>
        init(_ root: Host) {
            host = NSHostingView(rootView: root)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
        }
        func close() { window.orderOut(nil); window.contentView = nil }
    }

    private func findScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, scroll.documentView is EditorTextView { return scroll }
        return view.subviews.lazy.compactMap { self.findScrollView(in: $0) }.first
    }

    private func color(at location: Int, in view: NSTextView) -> NSColor? {
        view.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: location,
                                               effectiveRange: nil) as? NSColor
    }

    private func assertApplied(_ palette: EditorThemePalette, to scrollView: NSScrollView,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let textView = try XCTUnwrap(scrollView.documentView as? EditorTextView, file: file, line: line)
        XCTAssertEqual(textView.backgroundColor, palette.background, file: file, line: line)
        XCTAssertEqual(scrollView.backgroundColor, palette.background, file: file, line: line)
        XCTAssertEqual(textView.textColor, palette.text, file: file, line: line)
        XCTAssertEqual(textView.selectedTextAttributes[.backgroundColor] as? NSColor,
                       palette.selectedTextAttributes[.backgroundColor] as? NSColor, file: file, line: line)
        XCTAssertEqual(scrollView.appearance?.name, palette.appearanceName, file: file, line: line)
        let ruler = try XCTUnwrap(scrollView.verticalRulerView as? MarkdownLineNumberRulerView, file: file, line: line)
        XCTAssertEqual(ruler.palette, palette, file: file, line: line)
        XCTAssertEqual(color(at: 2, in: textView), palette.heading, file: file, line: line)
        let keyword = (textView.string as NSString).range(of: "const").location
        XCTAssertEqual(color(at: keyword, in: textView), palette.color(for: .codeToken(.keyword)),
                       file: file, line: line)
    }

    func testThemeChangeAppliesToEveryOpenEditorImmediately() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = EditorSettingsStore(defaults: defaults, prunesMissingDocuments: false, appearance: .light)
        let source = "# Title\n\n```js\nconst a = 1\n```\n"
        let windows = [Window(Host(settings: store, text: .constant(source), model: MarkdownEditorModel())),
                       Window(Host(settings: store, text: .constant(source), model: MarkdownEditorModel()))]
        defer { windows.forEach { $0.close() } }
        let scrollViews = try windows.map { try XCTUnwrap(findScrollView(in: $0.host)) }

        // 初回起動（設定なし）は既定の「紺色」。
        for scrollView in scrollViews {
            try assertApplied(EditorThemePalette(theme: EditorThemePalette.defaultTheme), to: scrollView)
        }
        XCTAssertEqual(scrollViews[0].appearance?.name, .darkAqua)

        for theme in [PreviewTheme.preset(.githubLight), .paper, .navy] {
            var settings = store.app
            settings.editorTheme = theme
            store.setAppSettings(settings)
            for window in windows { window.host.layoutSubtreeIfNeeded() }
            try await Task.sleep(for: .milliseconds(50))
            for window in windows { window.host.layoutSubtreeIfNeeded() }
            for scrollView in scrollViews {
                try assertApplied(EditorThemePalette(theme: theme), to: scrollView)
            }
        }
        XCTAssertEqual(scrollViews[0].appearance?.name, .darkAqua, "「紺色」は紺の背景に合わせてダークの外観にする")
    }

    /// 外観に合わせて切り替えているとき、macOSの外観が変わると開いている全エディタを塗り直す。
    func testAppearanceChangeRecolorsEveryOpenEditorWhenFollowingAppearance() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = EditorSettingsStore(defaults: defaults, prunesMissingDocuments: false, appearance: .light)
        let source = "# Title\n\n```js\nconst a = 1\n```\n"
        let windows = [Window(Host(settings: store, text: .constant(source), model: MarkdownEditorModel())),
                       Window(Host(settings: store, text: .constant(source), model: MarkdownEditorModel()))]
        defer { windows.forEach { $0.close() } }
        let scrollViews = try windows.map { try XCTUnwrap(findScrollView(in: $0.host)) }

        func settle() async throws {
            for window in windows { window.host.layoutSubtreeIfNeeded() }
            try await Task.sleep(for: .milliseconds(50))
            for window in windows { window.host.layoutSubtreeIfNeeded() }
        }

        var settings = store.app
        settings.editorThemeFollowsAppearance = true
        store.setAppSettings(settings)
        try await settle()
        // ライト外観では既定のGitHub風（ライト）。
        for scrollView in scrollViews {
            try assertApplied(EditorThemePalette(theme: .preset(.githubLight)), to: scrollView)
        }
        XCTAssertEqual(scrollViews[0].appearance?.name, .aqua)

        store.updateAppearance(.dark)
        try await settle()
        // ダーク外観では既定の「紺色」。
        for scrollView in scrollViews {
            try assertApplied(EditorThemePalette(theme: .navy), to: scrollView)
        }
        XCTAssertEqual(scrollViews[0].appearance?.name, .darkAqua)

        store.updateAppearance(.light)
        try await settle()
        for scrollView in scrollViews {
            try assertApplied(EditorThemePalette(theme: .preset(.githubLight)), to: scrollView)
        }
    }
}
