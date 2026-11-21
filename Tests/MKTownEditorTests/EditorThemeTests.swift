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

    func testUnsavedSettingsUseDarkEditorThemeAndKeepPreviewDefault() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = EditorSettingsStore(defaults: defaults, prunesMissingDocuments: false)

        XCTAssertNil(store.app.editorTheme)
        XCTAssertEqual(store.app.effectiveEditorTheme, .preset(.githubDark))
        XCTAssertEqual(store.app.effectiveEditorTheme.colorScheme, .dark)
        XCTAssertEqual(EditorThemePalette(theme: store.app.effectiveEditorTheme).appearanceName, .darkAqua)
        // プレビューの既定は従来どおり「システム」。
        XCTAssertNil(store.app.previewTheme)
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
        XCTAssertEqual(reopened.app.effectiveEditorTheme, .preset(.nord))
        XCTAssertNil(reopened.app.previewTheme)

        // 明示的に選んだ「システム」は、既定のダーク系に戻らない。
        settings = reopened.app
        settings.editorTheme = .system
        reopened.setAppSettings(settings)
        XCTAssertEqual(EditorSettingsStore(defaults: defaults, prunesMissingDocuments: false)
            .app.effectiveEditorTheme, .system)
    }

    func testEditorThemeIsStoredWithTheSameEncodingAsPreviewTheme() throws {
        var settings = AppEditorSettings()
        settings.editorTheme = .preset(.tomorrowNight)
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(settings), encoding: .utf8))
        XCTAssertTrue(json.contains("\"editorTheme\":\"tomorrow-night\""), json)
        // 以前の版で保存した設定（項目なし）は未設定として読む。
        let legacy = try JSONDecoder().decode(AppEditorSettings.self, from: Data("{\"defaultMode\":\"split\",\"fontSize\":13,\"lineSpacing\":3,\"wrapsLines\":true}".utf8))
        XCTAssertNil(legacy.editorTheme)
        XCTAssertEqual(legacy.effectiveEditorTheme, EditorThemePalette.defaultTheme)
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
        XCTAssertNil(settings.editorTheme, "編集画面は既定のダーク系に戻る")
        XCTAssertEqual(settings.previewTheme, .system)
        XCTAssertEqual(settings.extensionPackages, [])
    }

    // MARK: - 配色

    func testEveryThemeGivesReadableEditorColors() throws {
        for theme in PreviewTheme.allCases where theme != .system {
            let palette = EditorThemePalette(theme: theme)
            let background = palette.background
            XCTAssertEqual(palette.background, theme.background, theme.title)
            XCTAssertEqual(palette.appearanceName, theme.colorScheme == .dark ? .darkAqua : .aqua, theme.title)
            let roles: [MarkdownSyntaxSpan.Role] = [.heading, .code, .link, .marker, .quoteMarker, .listMarker,
                                                    .taskMarker, .tableMarker] +
                CodeSyntaxToken.allCases.map(MarkdownSyntaxSpan.Role.codeToken)
            for color in [palette.text, palette.lineNumber] + roles.map(palette.color(for:)) {
                XCTAssertGreaterThanOrEqual(PreviewTypography.contrastRatio(color, background), 4.5, theme.title)
            }
            let selection = try XCTUnwrap(palette.selection, theme.title)
            XCTAssertGreaterThanOrEqual(PreviewTypography.contrastRatio(palette.text, selection), 4.5, theme.title)
            XCTAssertEqual(palette.selectedTextAttributes[.foregroundColor] as? NSColor, palette.text)
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

    func testSystemPaletteKeepsAppearanceFollowingColors() {
        let palette = EditorThemePalette(theme: .system)
        XCTAssertEqual(palette, .system)
        XCTAssertNil(palette.appearanceName)
        XCTAssertNil(palette.selection)
        XCTAssertNil(palette.insertionPoint)
        XCTAssertEqual(palette.background, .textBackgroundColor)
        XCTAssertEqual(palette.text, .textColor)
        XCTAssertEqual(palette.heading, .systemBlue)
        XCTAssertEqual(palette.color(for: .codeToken(.keyword)), CodeSyntaxPalette.color(for: .keyword))
        XCTAssertEqual(palette.selectedTextAttributes[.backgroundColor] as? NSColor, .selectedTextBackgroundColor)
        XCTAssertEqual(palette.selectedTextAttributes[.foregroundColor] as? NSColor, .selectedTextColor)
    }

    func testHighlighterUsesPaletteColors() {
        let view = NSTextView()
        view.string = "# Title"
        let palette = EditorThemePalette(theme: .preset(.tomorrowNight))
        MarkdownSyntaxHighlighter.apply(to: view, palette: palette)
        XCTAssertEqual(color(at: 2, in: view), palette.heading)
        MarkdownSyntaxHighlighter.apply(to: view)
        XCTAssertEqual(color(at: 2, in: view), .systemBlue)
    }

    func testCoordinatorRecolorsSameSourceWhenPaletteChanges() {
        let view = NSTextView()
        view.string = "# Title\n\n```js\nconst a = 1\n```"
        let keyword = (view.string as NSString).range(of: "const").location
        let coordinator = MarkdownTextEditor.Coordinator(text: .constant(view.string), model: MarkdownEditorModel())
        coordinator.textView = view
        coordinator.refreshSyntax()
        XCTAssertEqual(color(at: 2, in: view), .systemBlue)

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
            MarkdownTextEditor(text: $text, model: model, theme: settings.app.effectiveEditorTheme)
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
        let store = EditorSettingsStore(defaults: defaults, prunesMissingDocuments: false)
        let source = "# Title\n\n```js\nconst a = 1\n```\n"
        let windows = [Window(Host(settings: store, text: .constant(source), model: MarkdownEditorModel())),
                       Window(Host(settings: store, text: .constant(source), model: MarkdownEditorModel()))]
        defer { windows.forEach { $0.close() } }
        let scrollViews = try windows.map { try XCTUnwrap(findScrollView(in: $0.host)) }

        // 初回起動（設定なし）はダーク系の既定テーマ。
        for scrollView in scrollViews {
            try assertApplied(EditorThemePalette(theme: EditorThemePalette.defaultTheme), to: scrollView)
        }

        for theme in [PreviewTheme.preset(.githubLight), .paper, .system] {
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
        XCTAssertNil(scrollViews[0].appearance, "「システム」はmacOSの外観に従う")
    }
}
