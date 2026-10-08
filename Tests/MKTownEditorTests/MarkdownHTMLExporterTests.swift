import Foundation
import XCTest
@testable import MKTownEditor

@MainActor
final class MarkdownHTMLExporterTests: XCTestCase {
    func testBasicDialectDoesNotExportExtendedTablesOrFootnotes() {
        let source = "| A |\n| --- |\n| B |\n\nText[^n]\n\n[^n]: Note"
        let extended = MarkdownHTMLExporter.render(source)
        let basic = MarkdownHTMLExporter.render(source, dialect: .basic)
        XCTAssertTrue(extended.contains("<table>"))
        XCTAssertTrue(extended.contains("class=\"footnotes\""))
        XCTAssertFalse(basic.contains("<table>"))
        XCTAssertFalse(basic.contains("class=\"footnotes\""))
        XCTAssertTrue(basic.contains("[^n]: Note"))
    }

    func testHTMLLanguageComesFromFrontMatterOrTheAppLocalization() {
        XCTAssertTrue(MarkdownHTMLExporter.render("---\nlang: en-GB\n---\n\nText").contains(#"<html lang="en-GB">"#))
        XCTAssertTrue(MarkdownHTMLExporter.render("---\nlang: \"fr\"\n---\n\nText").contains(#"<html lang="fr">"#))
        let fallback = Bundle.main.preferredLocalizations.first(where: { $0 != "Base" })
            ?? Bundle.main.developmentLocalization ?? "ja"
        XCTAssertTrue(MarkdownHTMLExporter.render("# 見出し\n\nこれは日本語で書いた本文です。").contains(#"<html lang="ja">"#))
        XCTAssertTrue(MarkdownHTMLExporter.render("This paragraph is written in plain English for the test.")
            .contains(#"<html lang="en">"#))
        for source in ["", "---\nlang: \"><script>\n---\n", "---\ntitle: x\n---\n\n```\ncode\n```"] {
            let html = MarkdownHTMLExporter.render(source)
            XCTAssertTrue(html.contains("<html lang=\"\(fallback)\">"), source)
            XCTAssertFalse(html.contains("<script>"))
        }
    }

    func testLimitedRawHTMLUsesSafeSubsetInExport() {
        let html = MarkdownHTMLExporter.render(
            "<strong>Safe</strong><!-- hidden --><script>alert('bad')</script> done")
        XCTAssertTrue(html.contains("<strong>Safe</strong>"))
        XCTAssertFalse(html.contains("hidden"))
        XCTAssertFalse(html.contains("alert('bad')"))
        XCTAssertFalse(html.contains("<script>"))
    }
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
        XCTAssertTrue(html.contains("tag"))
        XCTAssertFalse(html.contains("<tag>"))
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

    // Issue #41: mapped exports must reference files instead of embedding base64 or file: URLs.
    func testRelativeImageSourceReferencesMappedFilesWithoutEmbedding() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["photo.png", "unmapped.png", "voice.m4a", "guide.pdf"] {
            try Data([137, 80, 78, 71]).write(to: directory.appendingPathComponent(name))
        }
        func key(_ name: String) -> URL {
            directory.appendingPathComponent(name).resolvingSymlinksInPath().standardizedFileURL
        }
        let source = "![Photo](photo.png) ![Lost](unmapped.png) [guide](guide.pdf#page=2) [other](other.md)\n\n!audio[Voice](voice.m4a)"
        let html = MarkdownHTMLExporter.render(source, documentURL: directory.appendingPathComponent("note.md"),
            images: .relative(pathMap: [key("photo.png"): "assets/photo.png", key("voice.m4a"): "assets/voice.m4a",
                                        key("guide.pdf"): "assets/guide.pdf"]))
        XCTAssertTrue(html.contains("<img src=\"assets/photo.png\" alt=\"Photo\">"), html)
        XCTAssertTrue(html.contains("Lost"))
        XCTAssertFalse(html.contains("unmapped.png"), "unmapped images fall back to alt text")
        XCTAssertTrue(html.contains("href=\"assets/guide.pdf#page=2\""), html)
        XCTAssertTrue(html.contains("href=\"other.md\""), html)
        XCTAssertTrue(html.contains("<a href=\"assets/voice.m4a\">音声: Voice</a>"), html)
        XCTAssertFalse(html.contains("data:image/png"))
        XCTAssertFalse(html.contains("file:"))
    }

    func testStandaloneExportLinksMediaRelativeToOutputLocation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let media = root.appendingPathComponent("notes/media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([0]).write(to: media.appendingPathComponent("a:b c.m4a"))
        let document = root.appendingPathComponent("notes/note.md")
        let source = "!audio[Voice](media/a:b%20c.m4a)"
        let html = MarkdownHTMLExporter.render(source, documentURL: document,
                                               outputURL: root.appendingPathComponent("site/out/note.html"))
        XCTAssertTrue(html.contains("<a href=\"../../notes/media/a%3Ab%20c.m4a\">"), html)
        XCTAssertFalse(html.contains("file:"))
        XCTAssertFalse(html.contains(root.path))
        XCTAssertTrue(MarkdownHTMLExporter.render(source, documentURL: document).contains("href=\"file:"),
                      "without an output location, local uses keep the absolute file URL")
    }

    func testReferenceLinkAndDuplicateHeadingAnchors() {
        let markdown = "# Same\n\n# Same\n\n[Read][doc]\n\n[doc]: https://example.com"
        let html = MarkdownHTMLExporter.render(markdown)
        XCTAssertTrue(html.contains("id=\"same\""))
        XCTAssertTrue(html.contains("id=\"same-1\""))
        XCTAssertTrue(html.contains("href=\"https://example.com\""))
    }
}
