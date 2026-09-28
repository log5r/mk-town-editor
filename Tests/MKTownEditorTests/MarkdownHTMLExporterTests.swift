import Foundation
import XCTest
@testable import MKTownEditor

@MainActor
final class MarkdownHTMLExporterTests: XCTestCase {
    func testExportsSharedBlockStructureAndEscapesContent() {
        let markdown = """
        # Head & <tag>

        Text **bold** and [link](https://example.com/?a=1&b=2).

        - [x] done
        - next

        | A | B |
        | --- | ---: |
        | x | 2 |

        ```swift
        <script>&
        ```
        """
        let html = MarkdownHTMLExporter.render(markdown)
        let anchor = MarkdownHeadingIndex(analysis: MarkdownAnalysis(markdown)).anchors[0].slug
        XCTAssertTrue(html.contains("<h1 id=\"\(anchor)\">"))
        XCTAssertTrue(html.contains("&amp;"))
        XCTAssertTrue(html.contains("&lt;tag&gt;"))
        XCTAssertTrue(html.contains("<strong>bold</strong>"))
        XCTAssertTrue(html.contains("<ul>"))
        XCTAssertTrue(html.contains("<input type=\"checkbox\" disabled checked>"))
        XCTAssertTrue(html.contains("<table><thead>"))
        XCTAssertTrue(html.contains("text-align:right"))
        XCTAssertTrue(html.contains("<pre><code class=\"language-swift\">&lt;script&gt;&amp;"))
        XCTAssertFalse(html.contains("<script>"))
    }

    func testEmbedsLocalImageAndKeepsSafeLinks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("photo.png")
        try Data([137, 80, 78, 71]).write(to: image)
        let document = directory.appendingPathComponent("note.md")
        let html = MarkdownHTMLExporter.render("![Photo](photo.png) [site](https://example.com) [unsafe](javascript:alert(1))",
                                               documentURL: document)
        XCTAssertTrue(html.contains("src=\"data:image/png;base64,iVBORw==\""))
        XCTAssertTrue(html.contains("alt=\"Photo\""))
        XCTAssertTrue(html.contains("href=\"https://example.com\""))
        XCTAssertFalse(html.contains("href=\"javascript:"))
    }

    func testReferenceLinkAndDuplicateHeadingAnchors() {
        let markdown = "# Same\n\n# Same\n\n[Read][doc]\n\n[doc]: https://example.com"
        let html = MarkdownHTMLExporter.render(markdown)
        XCTAssertTrue(html.contains("id=\"same\""))
        XCTAssertTrue(html.contains("id=\"same-1\""))
        XCTAssertTrue(html.contains("href=\"https://example.com\""))
    }
}
