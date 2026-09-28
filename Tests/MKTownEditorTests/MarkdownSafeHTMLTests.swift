import Foundation
import XCTest
@testable import MKTownEditor

final class MarkdownSafeHTMLTests: XCTestCase {
    func testCommentsAreHiddenWithoutChangingSourcePositions() {
        let source = "before <!-- hidden\ncomment --> after"
        XCTAssertEqual(MarkdownSafeHTML.previewMarkdown(source), "before  after")
        XCTAssertEqual(source, "before <!-- hidden\ncomment --> after")
    }

    func testAllowedFormattingAndSafeLinksBecomeMarkdown() {
        XCTAssertEqual(MarkdownSafeHTML.previewMarkdown("<strong>Bold</strong> and <em>italic</em><br><code>x</code>"),
                       "**Bold** and _italic_\n`x`")
        XCTAssertEqual(MarkdownSafeHTML.previewMarkdown("<a href=\"https://example.com/a\">link</a>"),
                       "[link](<https://example.com/a>)")
    }

    func testScriptAndStylesAreNotInterpretedOrRendered() {
        let result = MarkdownSafeHTML.previewMarkdown(
            "start<script>alert('bad')</script><style>body{display:none}</style>end")
        XCTAssertFalse(result.contains("alert"))
        XCTAssertFalse(result.contains("display:none"))
        XCTAssertTrue(result.contains("script"))
        XCTAssertTrue(result.contains("style"))
        XCTAssertTrue(result.hasPrefix("start"))
        XCTAssertTrue(result.hasSuffix("end"))
    }

    func testUnsupportedTagsAreVisibleAndInlineCodeIsPreserved() {
        let result = MarkdownSafeHTML.previewMarkdown("`<strong>x</strong>` <custom>text</custom>")
        XCTAssertTrue(result.contains("`<strong>x</strong>`"))
        XCTAssertTrue(result.contains("custom"))
        XCTAssertTrue(result.contains("text"))
    }

    func testUnsafeLinkSchemeDoesNotBecomeClickable() {
        let result = MarkdownSafeHTML.previewMarkdown("<a href='javascript:alert(1)'>do not open</a>")
        XCTAssertFalse(result.contains("](<javascript:"))
        XCTAssertTrue(result.contains("do not open"))
    }

    func testMarkdownAutolinksAreNotMistakenForHTML() {
        let source = "<https://example.com> <person@example.com>"
        XCTAssertEqual(MarkdownSafeHTML.previewMarkdown(source), source)
    }

    func testHTMLCodeShowsMarkupAsLiteralText() {
        XCTAssertEqual(MarkdownSafeHTML.previewMarkdown("<code><script>x</script></code>"),
                       "`<script>x</script>`")
    }
}
