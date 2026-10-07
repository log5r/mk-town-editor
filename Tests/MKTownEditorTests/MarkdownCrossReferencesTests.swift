import AppKit
import XCTest
@testable import MKTownEditor

@MainActor
final class MarkdownCrossReferencesTests: XCTestCase {
    private let source = """
    ![Overview](overview.png)

    {#fig:overview}

    | A | B |
    |---|---|
    | 1 | 2 |

    {#tbl:data}

    $$
    x^2+y^2=z^2
    $$

    {#eq:pythagoras}

    See @fig:overview, @tbl:data and @eq:pythagoras.
    """

    func testStableExplicitIDsAndIndependentNumbers() {
        let analysis = MarkdownAnalysis(source)
        XCTAssertEqual(analysis.crossReferences.targets.map(\.key),
                       ["fig:overview", "tbl:data", "eq:pythagoras"])
        XCTAssertEqual(analysis.crossReferences.targets.map(\.number), [1, 1, 1])
        XCTAssertEqual(analysis.crossReferences.markerBlockIDs.count, 3)
        let visible = PreviewLayoutIndex(analysis).visibleBlocks
        XCTAssertFalse(visible.contains(where: { $0.content == "{#fig:overview}" }))
        XCTAssertEqual(analysis.crossReferences.replaceInline("@fig:overview `@tbl:data` @eq:pythagoras"),
                       "図1 `@tbl:data` 式(1)")
        XCTAssertEqual(analysis.crossReferences.replaceInline("@fig:missing \\@fig:overview @fig:overview.extra"),
                       "@fig:missing \\@fig:overview @fig:overview.extra")
    }

    func testPreviewHTMLAndPDFUseSameLabelsAndAnchors() throws {
        let attributed = MarkdownRenderer.render(source)
        let rendered = attributed.string
        XCTAssertTrue(rendered.contains("See 図1, 表1 and 式(1)."), rendered)
        XCTAssertFalse(rendered.contains("{#fig:overview}"))
        let reference = (rendered as NSString).range(of: "See 図1")
        let link = attributed.attribute(.link, at: reference.location + 4,
                                        effectiveRange: nil) as? URL
        XCTAssertEqual(link?.absoluteString, "mktown-crossref:///fig:overview")
        let html = MarkdownHTMLExporter.render(source)
        XCTAssertTrue(html.contains("id=\"fig:overview\""))
        XCTAssertTrue(html.contains("id=\"tbl:data\""))
        XCTAssertTrue(html.contains("id=\"eq:pythagoras\""))
        XCTAssertTrue(html.contains("See <a href=\"#fig:overview\">"))
        XCTAssertTrue(html.contains("<a href=\"#fig:overview\">図1</a>"))
        let output = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("refs.pdf")
        let view = try MarkdownPDFExporter.printableView(source, documentURL: nil,
            printInfo: MarkdownPDFExporter.printInfo(destination: output))
        XCTAssertTrue(view.string.contains("See 図1, 表1 and 式(1)."), view.string)
    }

    func testDuplicateAndMismatchedMarkersRemainVisible() {
        let markdown = """
        ![One](a.png)

        {#fig:same}

        ![Two](b.png)

        {#fig:same}

        {#tbl:wrong}
        """
        let analysis = MarkdownAnalysis(markdown)
        XCTAssertEqual(analysis.crossReferences.targets.count, 1)
        XCTAssertEqual(analysis.crossReferences.markerBlockIDs.count, 1)
        XCTAssertTrue(MarkdownRenderer.render(markdown).string.contains("{#fig:same}"))
        XCTAssertTrue(MarkdownRenderer.render(markdown).string.contains("{#tbl:wrong}"))
    }

    func testBasicDialectLeavesMarkersAndReferencesLiteral() {
        let analysis = MarkdownAnalysis(source, dialect: .basic)
        XCTAssertTrue(analysis.crossReferences.targets.isEmpty)
        let html = MarkdownHTMLExporter.render(source, dialect: .basic)
        XCTAssertTrue(html.contains("@fig:overview"))
        XCTAssertFalse(html.contains("id=\"fig:overview\""))
    }

    func testInlineReplacementScansUTF16WithoutChangingSemantics() {
        let references = MarkdownAnalysis(source).crossReferences
        XCTAssertEqual(references.replaceInline("日本🙂@fig:overview。``@tbl:data`` @tbl:data:x @eq:pythagoras"),
                       "日本🙂図1。``@tbl:data`` @tbl:data:x 式(1)")
        XCTAssertEqual(references.replaceInline("先頭なし"), "先頭なし")
        let placeholders = references.placeholders(in: "@fig:overview と @tbl:data")
        XCTAssertEqual(placeholders.text, "MKTOWNCROSSREFERENCE0END と MKTOWNCROSSREFERENCE1END")
        XCTAssertEqual(placeholders.targets.map(\.1.key), ["fig:overview", "tbl:data"])
        XCTAssertEqual(references.target(forBlockID: references.targets[1].blockID)?.key, "tbl:data")
    }

    func testInlineReplacementIsLinearForManyReferences() {
        let references = MarkdownAnalysis(source).crossReferences
        let paragraph = String(repeating: "本文 @fig:overview と @unknown ", count: 20_000)
        let start = Date()
        let replaced = references.replaceInline(paragraph)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertEqual(replaced, String(repeating: "本文 図1 と @unknown ", count: 20_000))
    }
}
