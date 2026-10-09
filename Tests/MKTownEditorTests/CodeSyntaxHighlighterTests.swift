import AppKit
import XCTest
@testable import MKTownEditor

@MainActor
final class CodeSyntaxHighlighterTests: XCTestCase {
    func testSwiftHighlightSeparatesKeywordsStringsCommentsAndNumbers() {
        let values = tokens("let count = 42\nlet text = \"if // still string\" // comment", "swift")

        XCTAssertTrue(values.contains { $0 == ("let", .keyword) })
        XCTAssertTrue(values.contains { $0 == ("42", .number) })
        XCTAssertTrue(values.contains { $0 == ("\"if // still string\"", .string) })
        XCTAssertTrue(values.contains { $0 == ("// comment", .comment) })
        XCTAssertFalse(values.contains { $0.0 == "if" })
    }

    func testAliasesAndUnsupportedLanguages() {
        XCTAssertTrue(tokens("def work(): # note", "py").contains { $0.1 == .keyword })
        XCTAssertTrue(tokens("const value = 1", "js").contains { $0.1 == .keyword })
        XCTAssertTrue(tokens("{\"ok\": true}", "json").contains { $0.1 == .keyword })
        XCTAssertTrue(tokens("int main() {}", "c++").contains { $0 == ("int", .type) })
        XCTAssertTrue(tokens("let x = 1", "unknown").isEmpty)
        XCTAssertTrue(tokens("let x = 1", nil).isEmpty)
        for plain in ["text", "txt", "plaintext", "Text"] {
            XCTAssertNil(CodeSyntaxTokenizer.language(named: plain), plain)
        }
    }

    func testFenceInfoWithFileNameAttributesOrExtensionSelectsLanguage() {
        XCTAssertEqual(CodeSyntaxTokenizer.language(named: "ruby:app.rb")?.name, "ruby")
        XCTAssertEqual(CodeSyntaxTokenizer.language(named: "{.python}")?.name, "python")
        XCTAssertEqual(CodeSyntaxTokenizer.language(named: "language-go")?.name, "go")
        XCTAssertEqual(CodeSyntaxTokenizer.language(named: "main.cpp")?.name, "cpp")
        XCTAssertEqual(CodeSyntaxTokenizer.language(named: "CPP")?.name, "cpp")
        XCTAssertNil(CodeSyntaxTokenizer.language(named: "notes.txt"))
    }

    func testEveryAliasResolvesToADefinedLanguage() {
        for (alias, canonical) in CodeSyntaxLanguages.aliases {
            XCTAssertNotNil(CodeSyntaxLanguages.all[canonical], alias)
        }
        for language in MarkdownCodeLanguage.allCases where language != .markdown {
            XCTAssertNotNil(CodeSyntaxTokenizer.language(named: language.rawValue), language.rawValue)
        }
    }

    func testCFamilyPreprocessorCharLiteralsAndBlockComments() {
        let values = tokens("#include <stdio.h>\n/* a\n b */\nint main(void) {\n  char c = 'x';\n  return 0x1F;\n}", "c")

        XCTAssertTrue(values.contains { $0 == ("#include", .attribute) })
        XCTAssertTrue(values.contains { $0 == ("<stdio.h>", .string) })
        XCTAssertTrue(values.contains { $0 == ("/* a\n b */", .comment) })
        XCTAssertTrue(values.contains { $0 == ("int", .type) })
        XCTAssertTrue(values.contains { $0 == ("'x'", .string) })
        XCTAssertTrue(values.contains { $0 == ("return", .keyword) })
        XCTAssertTrue(values.contains { $0 == ("0x1F", .number) })
        XCTAssertFalse(values.contains { $0.0 == "main" })
    }

    func testJavaAnnotationsAndCapitalizedTypes() {
        let values = tokens("@Override\npublic String name() { return MAX_SIZE; }", "java")

        XCTAssertTrue(values.contains { $0 == ("@Override", .attribute) })
        XCTAssertTrue(values.contains { $0 == ("public", .keyword) })
        XCTAssertTrue(values.contains { $0 == ("String", .type) })
        XCTAssertFalse(values.contains { $0.0 == "MAX_SIZE" })
    }

    func testRustLifetimesDoNotStartStringsAndMacrosAreMarked() {
        let values = tokens("#[derive(Debug)]\nfn get<'a>(x: &'a str) -> char { println!(\"{}\", x); 'z' }", "rust")

        XCTAssertTrue(values.contains { $0 == ("#[derive(Debug)]", .attribute) })
        XCTAssertTrue(values.contains { $0 == ("fn", .keyword) })
        XCTAssertTrue(values.contains { $0 == ("str", .type) })
        XCTAssertTrue(values.contains { $0 == ("println!", .attribute) })
        XCTAssertTrue(values.contains { $0 == ("\"{}\"", .string) })
        XCTAssertTrue(values.contains { $0 == ("'z'", .string) })
        XCTAssertFalse(values.contains { $0.0.hasPrefix("'a") })
    }

    func testPythonTripleQuotesPrefixesAndDecorators() {
        let values = tokens("@cache\ndef f():\n    \"\"\"doc\n    more\"\"\"\n    return f\"{x}\" # done", "python")

        XCTAssertTrue(values.contains { $0 == ("@cache", .attribute) })
        XCTAssertTrue(values.contains { $0 == ("\"\"\"doc\n    more\"\"\"", .string) })
        XCTAssertTrue(values.contains { $0 == ("f\"{x}\"", .string) })
        XCTAssertTrue(values.contains { $0 == ("# done", .comment) })
    }

    func testShellVariablesAndHashOnlyCommentsAtWordStart() {
        let values = tokens("for f in *.md; do\n  echo \"$f\" ${HOME} $# a#b # note\ndone", "bash")

        XCTAssertTrue(values.contains { $0 == ("for", .keyword) })
        XCTAssertTrue(values.contains { $0 == ("${HOME}", .variable) })
        XCTAssertTrue(values.contains { $0 == ("$#", .variable) })
        XCTAssertTrue(values.contains { $0 == ("# note", .comment) })
        XCTAssertFalse(values.contains { $0.1 == .comment && $0.0.contains("a#b") })
    }

    func testHashCommentsAfterIdentifiersOutsideShellStyleLanguages() {
        // Python などでは識別子や数値の直後の `#` もコメントになる。
        XCTAssertTrue(tokens("x=1#comment", "python").contains { $0 == ("#comment", .comment) })
        XCTAssertTrue(tokens("puts x#note", "ruby").contains { $0 == ("#note", .comment) })
        XCTAssertTrue(tokens("$a=1;#note", "php").contains { $0 == ("#note", .comment) })
        XCTAssertTrue(tokens("$x#note", "powershell").contains { $0 == ("#note", .comment) })
        // シェル系では単語の先頭の `#` だけをコメントにする。
        XCTAssertFalse(tokens("echo a#b", "bash").contains { $0.1 == .comment })
        XCTAssertFalse(tokens("url: a#b", "yaml").contains { $0.1 == .comment })
        XCTAssertFalse(tokens("key = a;b", "ini").contains { $0.1 == .comment })
        XCTAssertFalse(tokens("print $#array", "perl").contains { $0.1 == .comment })
    }

    func testSQLKeywordsIgnoreCase() {
        let values = tokens("SELECT id FROM users WHERE name = 'a' -- note", "sql")

        XCTAssertTrue(values.contains { $0 == ("SELECT", .keyword) })
        XCTAssertTrue(values.contains { $0 == ("FROM", .keyword) })
        XCTAssertTrue(values.contains { $0 == ("'a'", .string) })
        XCTAssertTrue(values.contains { $0 == ("-- note", .comment) })
    }

    func testJSONKeysAndYAMLKeysAreAttributes() {
        let json = tokens("{\"name\": \"value\", \"n\": 1}", "json")
        XCTAssertTrue(json.contains { $0 == ("\"name\"", .attribute) })
        XCTAssertTrue(json.contains { $0 == ("\"value\"", .string) })
        XCTAssertTrue(json.contains { $0 == ("1", .number) })

        let yaml = tokens("server:\n  - host: example.com # main\n    enabled: true\nurl: http://x", "yml")
        XCTAssertTrue(yaml.contains { $0 == ("server", .attribute) })
        XCTAssertTrue(yaml.contains { $0 == ("host", .attribute) })
        XCTAssertTrue(yaml.contains { $0 == ("enabled", .attribute) })
        XCTAssertTrue(yaml.contains { $0 == ("true", .keyword) })
        XCTAssertTrue(yaml.contains { $0 == ("# main", .comment) })
        XCTAssertFalse(yaml.contains { $0.0.contains("//x") })
    }

    func testMarkupTagsAttributesAndComments() {
        let values = tokens("<!-- c -->\n<a href=\"/x\" data-id=7>&amp;</a>", "html")

        XCTAssertTrue(values.contains { $0 == ("<!-- c -->", .comment) })
        XCTAssertTrue(values.contains { $0 == ("a", .keyword) })
        XCTAssertTrue(values.contains { $0 == ("href", .attribute) })
        XCTAssertTrue(values.contains { $0 == ("\"/x\"", .string) })
        XCTAssertTrue(values.contains { $0 == ("data-id", .attribute) })
        XCTAssertTrue(values.contains { $0 == ("7", .string) })
        XCTAssertTrue(values.contains { $0 == ("&amp;", .variable) })
        // 閉じタグも名前だけを色分けする。
        XCTAssertEqual(values.filter { $0.1 == .keyword }.map(\.0), ["a", "a"])
    }

    func testCSSSelectorsPropertiesAndValues() {
        let values = tokens(".box:hover { margin: 4px; color: #fff !important; }", "css")

        XCTAssertTrue(values.contains { $0 == (".box", .type) })
        XCTAssertTrue(values.contains { $0 == (":hover", .type) })
        XCTAssertTrue(values.contains { $0 == ("margin", .attribute) })
        XCTAssertTrue(values.contains { $0 == ("4px", .number) })
        XCTAssertTrue(values.contains { $0 == ("#fff", .number) })
        XCTAssertTrue(values.contains { $0 == ("!important", .keyword) })
    }

    func testDiffLines() {
        let values = tokens("--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n same", "diff")

        XCTAssertTrue(values.contains { $0 == ("--- a/x", .keyword) })
        XCTAssertTrue(values.contains { $0 == ("@@ -1 +1 @@", .attribute) })
        XCTAssertTrue(values.contains { $0 == ("-old", .deleted) })
        XCTAssertTrue(values.contains { $0 == ("+new", .inserted) })
        XCTAssertFalse(values.contains { $0.0 == " same" })
    }

    func testUnterminatedConstructsStopAtBlockEndAndRangesStayInBounds() {
        let sources = ["\"open", "/* open", "'", "#", "@", "0x", "<a href=", "<!--", "${", "#[", "`"]
        for name in Set(CodeSyntaxLanguages.aliases.values) {
            for source in sources {
                let length = (source as NSString).length
                for token in CodeSyntaxTokenizer.tokens(in: source, language: name) {
                    XCTAssertGreaterThan(token.range.length, 0, "\(name) \(source)")
                    XCTAssertLessThanOrEqual(NSMaxRange(token.range), length, "\(name) \(source)")
                }
            }
        }
    }

    func testTokensAreOrderedAndUseUTF16Offsets() {
        let source = "let 😀 = \"日本語\" // 説明"
        let result = CodeSyntaxTokenizer.tokens(in: source, language: "swift")
        XCTAssertEqual(result.map(\.range.location), result.map(\.range.location).sorted())
        let text = source as NSString
        XCTAssertTrue(result.contains { text.substring(with: $0.range) == "\"日本語\"" && $0.token == .string })
        XCTAssertTrue(result.contains { text.substring(with: $0.range) == "// 説明" && $0.token == .comment })
    }

    func testRendererUsesFenceLanguageAndPreservesPlainFallback() throws {
        let highlighted = MarkdownRenderer.render("```swift\nlet x = 1\n```")
        let plain = MarkdownRenderer.render("```unknown\nlet x = 1\n```")
        let keyword = (highlighted.string as NSString).range(of: "let")
        XCTAssertEqual(highlighted.attribute(.foregroundColor, at: keyword.location,
                                             effectiveRange: nil) as? NSColor,
                       CodeSyntaxPalette.color(for: .keyword))
        XCTAssertEqual(highlighted.attribute(.codeSyntaxToken, at: keyword.location,
                                             effectiveRange: nil) as? String, "keyword")
        XCTAssertEqual(plain.attribute(.foregroundColor, at: keyword.location,
                                       effectiveRange: nil) as? NSColor, .textColor)
        XCTAssertEqual(highlighted.string, plain.string)
        XCTAssertNotNil(highlighted.attribute(.font, at: keyword.location, effectiveRange: nil))
    }

    func testPaperThemeRecolorsTokensAndExtensionThemeKeepsCodeColor() throws {
        let rendered = CodeSyntaxHighlighter.render("let x = \"a\"", language: "swift")
        let paper = PreviewTypography.themed(rendered, kind: .codeBlock, theme: .paper)
        XCTAssertEqual(paper.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                       CodeSyntaxPalette.color(CodeSyntaxPalette.paper[.keyword]!))
        XCTAssertEqual(paper.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? NSColor,
                       PreviewTheme.paper.codeColor)

        let theme = DeclarativeExtension.Theme(name: "Ink", background: "#FFFFFF", body: "#000000",
                                               heading: "#000000", code: "#111111", link: "#000080",
                                               codeBackground: "#F0F0F0")
        let custom = PreviewTypography.themed(rendered, kind: .codeBlock, theme: .extensionTheme(theme))
        XCTAssertEqual(custom.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                       theme.color(\.code))
    }

    func testPalettesMeetTextContrastAgainstCodeBackgrounds() throws {
        let backgrounds: [(String, [CodeSyntaxToken: String], [String])] = [
            // システムの白・暗い背景と、HTML の `pre` が文字色を 8% 混ぜた背景。
            ("light", CodeSyntaxPalette.light, ["#FFFFFF", "#EBEBEB"]),
            ("dark", CodeSyntaxPalette.dark, ["#1E1E1E", "#323232"]),
            ("paper", CodeSyntaxPalette.paper, ["#E8DEC9"])
        ]
        for (name, palette, colors) in backgrounds {
            XCTAssertEqual(Set(palette.keys), Set(CodeSyntaxToken.allCases), name)
            for (token, hex) in palette {
                for background in colors {
                    let ratio = PreviewTypography.contrastRatio(CodeSyntaxPalette.color(hex),
                                                                CodeSyntaxPalette.color(background))
                    XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(name) \(token) on \(background)")
                }
            }
        }
    }

    func testDynamicColorsFollowAppearance() throws {
        let color = CodeSyntaxPalette.color(for: .keyword)
        for (appearance, hex) in [(NSAppearance.Name.aqua, CodeSyntaxPalette.light[.keyword]!),
                                  (.darkAqua, CodeSyntaxPalette.dark[.keyword]!)] {
            var resolved: NSColor?
            try XCTUnwrap(NSAppearance(named: appearance)).performAsCurrentDrawingAppearance {
                resolved = color.usingColorSpace(.sRGB)
            }
            let expected = CodeSyntaxPalette.color(hex)
            XCTAssertEqual(resolved?.redComponent ?? -1, expected.redComponent, accuracy: 0.01)
            XCTAssertEqual(resolved?.blueComponent ?? -1, expected.blueComponent, accuracy: 0.01)
        }
    }

    // MARK: - HTML

    func testHTMLExportWrapsTokensInEscapedSpans() {
        let html = MarkdownHTMLExporter.render("```cpp\nif (a < b) return \"<x>\";\n```", documentURL: nil)

        XCTAssertTrue(html.contains("<code class=\"language-cpp\"><span class=\"tok-keyword\">if</span> (a &lt; b) "
                                    + "<span class=\"tok-keyword\">return</span> "
                                    + "<span class=\"tok-string\">&quot;&lt;x&gt;&quot;</span>;</code>"), html)
        XCTAssertTrue(html.contains(".tok-keyword { color: \(CodeSyntaxPalette.light[.keyword]!); }"))
        XCTAssertTrue(html.contains("prefers-color-scheme: dark) { .tok-keyword { color: \(CodeSyntaxPalette.dark[.keyword]!); }"))
    }

    func testHTMLExportLeavesPlainAndUnknownCodeUnchanged() {
        let html = MarkdownHTMLExporter.render("```text\nif <x>\n```\n\n```\nlet y\n```", documentURL: nil)
        XCTAssertTrue(html.contains("<code class=\"language-text\">if &lt;x&gt;</code>"), html)
        XCTAssertTrue(html.contains("<pre><code>let y</code></pre>"), html)
        XCTAssertFalse(html.contains("<span class=\"tok-"))
    }

    func testPrintLayoutUsesOnlyLightTokenColors() throws {
        let styles = MarkdownHTMLExporter.codeTokenStyles(printLayout: true)
        XCTAssertFalse(styles.contains("prefers-color-scheme"))

        let view = try MarkdownPDFExporter.printableView("```swift\nlet x = 1\n```", documentURL: nil,
                                                          printInfo: NSPrintInfo())
        let storage = try XCTUnwrap(view.textStorage)
        let keyword = (storage.string as NSString).range(of: "let")
        let color = try XCTUnwrap(storage.attribute(.foregroundColor, at: keyword.location,
                                                    effectiveRange: nil) as? NSColor).usingColorSpace(.sRGB)
        let expected = CodeSyntaxPalette.color(CodeSyntaxPalette.light[.keyword]!)
        XCTAssertEqual(color?.redComponent ?? -1, expected.redComponent, accuracy: 0.02)
        XCTAssertEqual(color?.greenComponent ?? -1, expected.greenComponent, accuracy: 0.02)
    }

    private func tokens(_ source: String, _ language: String?) -> [(String, CodeSyntaxToken)] {
        let text = source as NSString
        return CodeSyntaxTokenizer.tokens(in: source, language: language).map {
            (text.substring(with: $0.range), $0.token)
        }
    }
}
