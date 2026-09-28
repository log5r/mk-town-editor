import AppKit
import XCTest
@testable import MKTownEditor

@MainActor
final class RichTextMarkdownImporterTests: XCTestCase {
    func testHTMLConvertsHeadingsEmphasisLinksAndLists() throws {
        let html = """
        <html><body><h1>Title</h1><p>Intro <strong>bold</strong> and
        <a href="https://example.com">link</a>.</p><ul><li>one</li><li>two</li></ul></body></html>
        """
        let result = try RichTextMarkdownImporter.convert(Data(html.utf8), format: .html)
        XCTAssertTrue(result.markdown.contains("# "), result.markdown)
        XCTAssertTrue(result.markdown.contains("bold"), result.markdown)
        XCTAssertTrue(result.markdown.contains("[link](https://example.com/)"), result.markdown)
        XCTAssertTrue(result.markdown.contains("- one"), result.markdown)
        XCTAssertTrue(result.markdown.contains("- two"), result.markdown)
        XCTAssertTrue(result.markdown.contains("# Title\n\nIntro"), result.markdown)
        XCTAssertTrue(result.markdown.contains("- one\n- two"), result.markdown)
    }

    func testHTMLReportsImagesAndStyleLossBeforeApplying() throws {
        let html = """
        <html><head><style>p { color: red; }</style></head><body>
        <script>privateToken()</script>
        <p>Before <img src="https://example.com/private.png" alt="photo"> after</p>
        <table><tr><td>cell</td></tr></table></body></html>
        """
        let result = try RichTextMarkdownImporter.convert(Data(html.utf8), format: .html)
        XCTAssertTrue(result.markdown.contains("画像: photo"), result.markdown)
        XCTAssertFalse(result.markdown.contains("privateToken"), result.markdown)
        XCTAssertEqual(result.warnings.count, 3)
        XCTAssertTrue(result.warnings.contains { $0.contains("画像") })
        XCTAssertTrue(result.warnings.contains { $0.contains("表") })
        XCTAssertTrue(result.warnings.contains { $0.contains("CSS") })
    }

    func testRTFPlainTextAndUnsupportedFiles() throws {
        let source = NSAttributedString(string: "Hello\nWorld")
        let data = try source.data(from: NSRange(location: 0, length: source.length),
                                   documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let result = try RichTextMarkdownImporter.convert(data, format: .rtf)
        XCTAssertTrue(result.markdown.contains("Hello"))
        XCTAssertTrue(result.markdown.contains("World"))
        XCTAssertNil(RichTextImportFormat(url: URL(fileURLWithPath: "/tmp/file.docx")))
        XCTAssertThrowsError(try RichTextMarkdownImporter.convert(
            Data(repeating: 65, count: 10_000_001), format: .html))
    }

    func testShiftJISHTMLUsesDeclaredEncoding() throws {
        let html = "<html><head><meta charset=Shift_JIS></head><body><p>日本語</p></body></html>"
        let data = try XCTUnwrap(html.data(using: .shiftJIS))
        let result = try RichTextMarkdownImporter.convert(data, format: .html)
        XCTAssertTrue(result.markdown.contains("日本語"), result.markdown)
    }
}
