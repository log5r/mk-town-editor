import AppKit
import SwiftUI
import XCTest
@testable import MKTownEditor

@MainActor
final class PreviewThemePresetTests: XCTestCase {
    private func package(syntax: String = "", link: String = "#0969DA") -> String {
        """
        {"schemaVersion":1,"id":"example.theme","name":"Example",
         "theme":{"name":"Example","background":"#FFFFFF","body":"#1F2328",
           "heading":"#1F2328","code":"#1F2328","link":"\(link)",
           "codeBackground":"#F6F8FA"\(syntax)}}
        """
    }

    private func load(_ json: String) throws -> DeclarativeExtension {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        try json.write(to: file, atomically: true, encoding: .utf8)
        return try DeclarativeExtension.load(from: file)
    }

    func testEveryPresetDefinesAllColorsWithReadableContrast() throws {
        XCTAssertEqual(Set(PreviewThemePreset.allCases.map(\.title)).count, PreviewThemePreset.allCases.count)
        for preset in PreviewThemePreset.allCases {
            let theme = preset.theme
            // カスタムテーマと同じ検査（色の書式、字句名、4.5:1 以上のコントラスト）を通す。
            XCTAssertNoThrow(try theme.validate(), preset.rawValue)
            XCTAssertEqual(Set(try XCTUnwrap(theme.syntax).keys),
                           Set(CodeSyntaxToken.allCases.map(\.rawValue)), preset.rawValue)
            let selected = PreviewTheme.preset(preset)
            let background = try XCTUnwrap(selected.background)
            let codeBackground = try XCTUnwrap(selected.codeBackground)
            for color in [selected.bodyColor, selected.headingColor, selected.linkColor, selected.codeColor] {
                XCTAssertGreaterThanOrEqual(
                    PreviewTypography.contrastRatio(try XCTUnwrap(color), background), 4.5, preset.rawValue)
            }
            for token in CodeSyntaxToken.allCases {
                let color = try XCTUnwrap(CodeSyntaxPalette.color(for: token, theme: selected))
                XCTAssertGreaterThanOrEqual(PreviewTypography.contrastRatio(color, codeBackground), 4.5,
                                            "\(preset.rawValue) \(token)")
            }
        }
    }

    func testPresetsAreOfferedAndFollowTheirBackgroundBrightness() {
        XCTAssertEqual(PreviewTheme.allCases.prefix(2), [.system, .paper])
        XCTAssertEqual(Array(PreviewTheme.allCases.dropFirst(2)),
                       PreviewThemePreset.allCases.map(PreviewTheme.preset))
        XCTAssertEqual(PreviewTheme.preset(.githubLight).colorScheme, .light)
        XCTAssertEqual(PreviewTheme.preset(.tomorrow).colorScheme, .light)
        for preset in [PreviewThemePreset.githubDark, .tomorrowNight, .dracula, .nord] {
            XCTAssertEqual(PreviewTheme.preset(preset).colorScheme, .dark, preset.rawValue)
        }
        XCTAssertEqual(PreviewTheme.preset(.nord).title, "Nord")
    }

    func testPresetIsStoredByNameAndSurvivesSettingsRoundTrip() throws {
        let data = try JSONEncoder().encode([PreviewTheme.preset(.tomorrowNight)])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "[\"tomorrow-night\"]")
        XCTAssertEqual(try JSONDecoder().decode([PreviewTheme].self, from: data), [.preset(.tomorrowNight)])
        XCTAssertThrowsError(try JSONDecoder().decode([PreviewTheme].self, from: Data("[\"unknown\"]".utf8)))

        let suite = "PreviewThemePresetTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = EditorSettingsStore(defaults: defaults)
        var settings = store.app
        settings.previewTheme = .preset(.dracula)
        store.setAppSettings(settings)
        XCTAssertEqual(EditorSettingsStore(defaults: defaults).app.previewTheme, .preset(.dracula))
    }

    func testPresetRecolorsCodeTokensHeadingsAndLinks() throws {
        let theme = PreviewTheme.preset(.githubLight)
        let code = PreviewTypography.themed(CodeSyntaxHighlighter.render("let x = \"a\"", language: "swift"),
                                            kind: .codeBlock, theme: theme)
        XCTAssertEqual(code.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                       CodeSyntaxPalette.color("#CF222E"))
        XCTAssertEqual(code.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? NSColor, theme.codeColor)
        XCTAssertEqual(code.attribute(.foregroundColor, at: 8, effectiveRange: nil) as? NSColor,
                       CodeSyntaxPalette.color("#0A3069"))

        let dracula = PreviewTheme.preset(.dracula)
        let heading = PreviewTypography.themed(NSAttributedString(string: "Title"),
                                               kind: .heading(level: 1), theme: dracula)
        XCTAssertEqual(heading.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                       CodeSyntaxPalette.color("#BD93F9"))
        let link = PreviewTypography.themed(MarkdownRenderer.render("[link](https://example.com)"),
                                            kind: .paragraph, theme: dracula)
        XCTAssertEqual(link.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                       dracula.linkColor)
    }

    func testCustomThemeSyntaxColorsApplyAndOmittedTokensKeepCodeColor() throws {
        let loaded = try load(package(syntax: ##","syntax":{"keyword":"#CF222E"}"##))
        let theme = PreviewTheme.extensionTheme(try XCTUnwrap(loaded.theme))
        let code = PreviewTypography.themed(CodeSyntaxHighlighter.render("let x = \"a\"", language: "swift"),
                                            kind: .codeBlock, theme: theme)
        XCTAssertEqual(code.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                       CodeSyntaxPalette.color("#CF222E"))
        // 字句の色を省いた文字列はコード色のまま。
        XCTAssertEqual(code.attribute(.foregroundColor, at: 8, effectiveRange: nil) as? NSColor, theme.codeColor)
        // 設定に保存しても字句の色が残る。
        let restored = try JSONDecoder().decode([PreviewTheme].self, from: JSONEncoder().encode([theme]))
        XCTAssertEqual(restored, [theme])
    }

    func testCustomThemeValidationAcceptsAAContrastAndRejectsBadSyntaxColors() throws {
        // リンクの #0969DA は白背景で約 5.2:1。以前の 7:1 の基準では読み込めなかった。
        XCTAssertNoThrow(try load(package()))
        XCTAssertThrowsError(try load(package(link: "#8E908C"))) {
            XCTAssertEqual($0 as? DeclarativeExtension.ExtensionError, .lowContrast)
        }
        XCTAssertThrowsError(try load(package(syntax: ##","syntax":{"comment":"#C0C0C0"}"##))) {
            XCTAssertEqual($0 as? DeclarativeExtension.ExtensionError, .lowContrast)
        }
        XCTAssertThrowsError(try load(package(syntax: ##","syntax":{"function":"#000000"}"##))) {
            XCTAssertEqual($0 as? DeclarativeExtension.ExtensionError, .invalidTheme)
        }
        XCTAssertThrowsError(try load(package(syntax: ##","syntax":{"keyword":"red"}"##))) {
            XCTAssertEqual($0 as? DeclarativeExtension.ExtensionError, .invalidTheme)
        }
    }

    func testCustomThemeListSkipsPackagesWithoutThemeAndDuplicates() throws {
        let first = try load(package())
        let second = try load(package().replacingOccurrences(of: "example.theme", with: "example.copy"))
        let snippetsOnly = try load("""
        {"schemaVersion":1,"id":"example.snippets","name":"Snippets",
         "snippets":[{"trigger":"sig","template":"text"}]}
        """)
        var settings = AppEditorSettings()
        XCTAssertEqual(settings.customPreviewThemes, [])
        settings.extensionPackages = [first, snippetsOnly, second]
        XCTAssertEqual(settings.customPreviewThemes, [.extensionTheme(try XCTUnwrap(first.theme))])
    }

    /// docs/preview-themes.md に載せたサンプルが、そのまま読み込めること。
    func testDocumentedExampleThemeLoads() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let document = try String(contentsOf: root.appendingPathComponent("docs/preview-themes.md"), encoding: .utf8)
        let start = try XCTUnwrap(document.range(of: "```json\n"))
        let end = try XCTUnwrap(document.range(of: "\n```", range: start.upperBound..<document.endIndex))
        let loaded = try load(String(document[start.upperBound..<end.lowerBound]))
        let theme = try XCTUnwrap(loaded.theme)
        XCTAssertEqual(theme.name, "Soft Light")
        XCTAssertEqual(Set(try XCTUnwrap(theme.syntax).keys), Set(CodeSyntaxToken.allCases.map(\.rawValue)))
        XCTAssertEqual(PreviewTheme.extensionTheme(theme).colorScheme, .light)
    }

    /// 不具合: NSTextView がリンクを既定の青で描き、紙色を含むどのテーマでもリンク色が反映されなかった。
    func testLinkDrawingUsesThemeLinkColorInsteadOfDefaultBlue() throws {
        XCTAssertEqual(PreviewLinkStyle.textViewAttributes(for: .system)[.foregroundColor] as? NSColor,
                       NSColor.linkColor)
        let custom = PreviewTheme.extensionTheme(try XCTUnwrap(try load(package()).theme))
        for theme in [PreviewTheme.paper, .preset(.dracula), .preset(.githubLight), custom] {
            let link = try XCTUnwrap(theme.linkColor)
            let attributes = PreviewLinkStyle.textViewAttributes(for: theme)
            XCTAssertEqual(attributes[.foregroundColor] as? NSColor, link, theme.title)
            XCTAssertEqual(attributes[.underlineStyle] as? Int, NSUnderlineStyle.single.rawValue)
        }
    }

    /// docs/preview-theme-authoring.md に載せたサンプルが、すべてそのまま読み込めること。
    func testAuthoringGuideExamplesLoad() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let document = try String(contentsOf: root.appendingPathComponent("docs/preview-theme-authoring.md"),
                                  encoding: .utf8)
        var names: [String] = []
        var remaining = document[...]
        while let start = remaining.range(of: "```json\n"),
              let end = remaining.range(of: "\n```", range: start.upperBound..<remaining.endIndex) {
            let theme = try XCTUnwrap(try load(String(remaining[start.upperBound..<end.lowerBound])).theme)
            names.append(theme.name)
            remaining = remaining[end.upperBound...]
        }
        XCTAssertEqual(names, ["Plain Light", "Soft Dark"])
    }
}
