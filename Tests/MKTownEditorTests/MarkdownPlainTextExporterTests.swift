import XCTest
@testable import MKTownEditor

@MainActor
final class MarkdownPlainTextExporterTests: XCTestCase {
    func testOptionsControlLinksImagesAndFootnotes() {
        let source = """
        # 見出し

        **太字** [サイト](https://example.com) ![図](image.png) 本文[^a]

        [^a]: 脚注の内容
        """
        var options = MarkdownPlainTextOptions()
        let defaultText = MarkdownPlainTextExporter.render(source, options: options)
        XCTAssertTrue(defaultText.contains("見出し"))
        XCTAssertTrue(defaultText.contains("太字 サイト 図 本文[a]"))
        XCTAssertTrue(defaultText.contains("[a] 脚注の内容"))
        XCTAssertFalse(defaultText.contains("https://example.com"))
        options.linkDestinations = true
        options.imageDescriptions = false
        options.footnotes = false
        let minimalText = MarkdownPlainTextExporter.render(source, options: options)
        XCTAssertTrue(minimalText.contains("サイト (https://example.com)"))
        XCTAssertFalse(minimalText.contains("図"))
        XCTAssertFalse(minimalText.contains("脚注の内容"))
        XCTAssertFalse(minimalText.contains("[a]"))
    }

    func testTableAndCodeBlockKeepReadableContent() {
        let source = """
        | 名前 | 点数 |
        | --- | ---: |
        | 花子 | 42 |

        ```swift
        let n = 1
        ```
        """
        let result = MarkdownPlainTextExporter.render(source, options: MarkdownPlainTextOptions())
        XCTAssertTrue(result.contains("名前\t点数\n花子\t42"))
        XCTAssertTrue(result.contains("let n = 1"))
        XCTAssertFalse(result.contains("```"))
    }

    func testFootnoteSyntaxInsideCodeRemainsLiteral() {
        let source = """
        ```md
        [^sample]: code
        ```

        Text[^note]

        [^note]: **強調**した脚注
        """
        let result = MarkdownPlainTextExporter.render(source, options: MarkdownPlainTextOptions())
        XCTAssertTrue(result.contains("[^sample]: code"))
        XCTAssertTrue(result.contains("[note] 強調した脚注"))
        XCTAssertFalse(result.contains("**"))
    }
}
